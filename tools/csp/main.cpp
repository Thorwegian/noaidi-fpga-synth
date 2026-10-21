// main.cpp — `csp`, the CSP assembler and simulator on the host
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   csp asm program.s...
//       assemble; print each row (72 bits as two 36-bit halves, hex) with
//       its source line, then the decode ROM's rows and the pass's cycles
//   csp header program.s... [-n name]
//       assemble and print a C++ header: the rows, the ROM and every name (registers, blocks, fields) as a constant, for the
//       firmware (app/main/csp/control_program.hpp); the names are in
//       namespace csp::name (default control)
//   csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]... [-d]
//       assemble and run on the reference model: load the program with the
//       CSP held, release it, run `passes` passes (default 4) and print the
//       watched registers after each. -s queues a firmware write (raw
//       value) and swaps before the given pass. -d dumps every register
//       after the last pass, "address value" a line, raw.
//   csp script program.s... [-f seed] [-w address=raw]...
//       assemble and print the firmware console's commands that load the
//       program on the chip: csp-hold, the decode ROM's rows, the instruction
//       rows, the register writes given, csp-go. -f first fills every
//       register but the inputs with the firmware's csp-burst pattern,
//       (address × 37 + seed) & 0x1FFFF, so the chip and the model start
//       alike whatever the chip held. The dev box's claude_chipcheck.py sends
//       the lines and reads the registers back.
//   csp match program.s... -c chip.txt [-f seed] [-w address=raw]...
//       the chip's registers (csp-peek's lines, every pair) against the
//       model run from the same load for as many passes as the chip ran,
//       which the program counts in RUN_COUNT (0x3FE): the differing
//       registers, or none.
//
// Several program files are joined into one, in order (map.s first).
// Diagnostics go to stderr as file:line: error|warning: message; the exit
// status is 1 if there was an error, or if the model reported one.

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "assembler.hpp"
#include "processor.hpp"

namespace {

int usage() {
    std::fputs("usage: csp asm program.s...\n"
               "       csp header program.s... [-n name]\n"
               "       csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]... [-d]\n"
               "       csp script program.s... [-f seed] [-w address=raw]...\n"
               "       csp match program.s... -c chip.txt [-f seed] [-w address=raw]...\n"
               "       (several program files are joined into one, in order)\n",
               stderr);
    return 2;
}

bool read_file(const std::string &path, std::string &text) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream contents;
    contents << in.rdbuf();
    text = contents.str();
    return true;
}

// The files a program was joined from, to say which one a line is in.
struct Sources {
    struct Part {
        std::string path;
        int first_line; // of the joined text, from 1
    };
    std::vector<Part> parts;
    std::string text;

    std::string where(int line) const {
        const Part *part = &parts.front();
        for (const Part &candidate : parts) {
            if (candidate.first_line <= line) part = &candidate;
        }
        return part->path + ":" + std::to_string(line - part->first_line + 1);
    }
};

bool report(const Sources &sources, const csp::Program &program) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::fprintf(stderr, "%s: %s: %s\n", sources.where(d.line).c_str(), d.error ? "error" : "warning",
                     d.message.c_str());
    }
    return program.ok;
}

int assemble_command(const csp::Program &program) {
    const csp::Image &image = program.image;
    for (int row = 0; row < image.length; ++row) {
        const csp::Word word = csp::Word::decode(image.rows[static_cast<size_t>(row)]);
        const int line       = program.source_lines[static_cast<size_t>(row)];
        std::printf("%04x  %09llx %09llx  %-6s", row, static_cast<unsigned long long>(image.rows[static_cast<size_t>(row)].high),
                    static_cast<unsigned long long>(image.rows[static_cast<size_t>(row)].low),
                    line > 0 ? "" : "wait");
        if (line > 0) std::printf(" ; line %d", line);
        std::printf("\n");
        (void) word;
    }
    for (int row = 0; row < image.rom_used; ++row) {
        const csp::Control control = csp::Control::decode(image.rom[static_cast<size_t>(row)]);
        std::printf("rom %02x = %05x  unit %d writes %d a %d%s%s%s cond %d%s sub %d\n", row,
                    image.rom[static_cast<size_t>(row)], static_cast<int>(control.unit),
                    static_cast<int>(control.writes), static_cast<int>(control.a_source),
                    control.reads_x ? " x" : "", control.reads_y ? " y" : "", control.y_wide ? " wide-y" : "",
                    static_cast<int>(control.cond), control.wrap ? " wrap" : "", control.sub);
    }
    std::printf("%d rows, %d decode rows, %d cycles a pass\n", image.length, image.rom_used, program.cycles);
    return 0;
}

// A symbol as a C++ constant name: NAME_LIKE_THIS → name_like_this.
std::string constant_name(const std::string &symbol) {
    std::string name = symbol;
    std::ranges::transform(name, name.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return name;
}

// The header the firmware loads the program from. The format is the
// repository's (Java Code Conventions): `make format` leaves it be.
int header_command(const csp::Program &program, const std::vector<std::string> &files, const std::string &name_space) {
    const csp::Image &image = program.image;
    const bool control      = name_space == "control";
    std::printf("// %s_program.hpp — the CSP's %s, as machine code\n"
                "//\n"
                "// Copyright © 2026 Thor H. Linløkken <thj@thj.no>\n"
                "// License: CERN-OHL-S v2\n"
                "//\n"
                "// Generated by `csp header` (make csp-header) from, in this order:\n",
                control ? "control" : name_space.c_str(), control ? "control program" : "boot self-test");
    for (const std::string &file : files) std::printf("//   %s\n", file.c_str());
    std::printf("// Do not edit: make csp-test checks that it is current.\n"
                "// The names are those of tools/csp/programs/map.s, in lower case;\n"
                "// the labels of the code are left out.\n\n"
                "#pragma once\n\n"
                "// clang-format off\n"
                "#include <array>\n"
                "#include <cstdint>\n\n"
                "#include \"csp.hpp\"\n\n"
                "namespace csp::%s {\n\n",
                name_space.c_str());
    std::printf("// The pass's cycles, as scheduled.\n"
                "inline constexpr int cycles = %d;\n\n"
                "// The rows: 72 bits each, bits 71:36 then 35:0.\n"
                "inline constexpr std::array<Row, %d> rows{{\n",
                program.cycles, image.length);
    for (int row = 0; row < image.length; ++row) {
        const csp::Row &bits = image.rows[static_cast<size_t>(row)];
        std::printf("    {0x%09llxull, 0x%09llxull},\n", static_cast<unsigned long long>(bits.high),
                    static_cast<unsigned long long>(bits.low));
    }
    std::printf("}};\n\n"
                "// The decode ROM: one control word a row, row 0 the NOP.\n"
                "inline constexpr std::array<uint32_t, %d> rom{\n",
                image.rom_used);
    for (int row = 0; row < image.rom_used; row += 8) {
        std::printf("   ");
        for (int k = row; k < std::min(row + 8, image.rom_used); ++k) {
            std::printf(" 0x%05x,", image.rom[static_cast<size_t>(k)]);
        }
        std::printf("\n");
    }
    std::printf("};\n\n// Registers, blocks and fields.\n");
    for (const auto &[name, value] : program.symbols) {
        const bool label = std::ranges::any_of(name, [](unsigned char c) { return std::islower(c); });
        if (!label) std::printf("inline constexpr int %s = %d;\n", constant_name(name).c_str(), value);
    }
    std::printf("\n} // namespace csp::%s\n"
                "// clang-format on\n",
                name_space.c_str());
    return 0;
}

struct ScriptedWrite {
    int address;
    int32_t raw;
    int before_pass;
};

int simulate_command(const csp::Program &program, int passes, const std::vector<std::string> &watch,
                     const std::vector<ScriptedWrite> &writes, bool dump) {
    csp::Processor processor;
    processor.load(program.image);
    processor.release();
    processor.trace(std::getenv("CSP_TRACE") != nullptr);

    int status = 0;
    for (int pass = 1; pass <= passes; ++pass) {
        bool queued = false;
        for (const ScriptedWrite &write : writes) {
            if (write.before_pass == pass) {
                processor.write(write.address, write.raw);
                queued = true;
            }
        }
        if (queued) processor.swap();
        const csp::PassReport report = processor.pass();
        std::printf("pass %d: %d cycles", pass, report.cycles);
        for (const std::string &name : watch) {
            std::printf("  %s=%d", name.c_str(), processor.read(program.symbols.at(name)));
        }
        std::printf("\n");
        for (const std::string &error : report.errors) {
            std::printf("  error: %s\n", error.c_str());
            status = 1;
        }
        for (int stale : report.stale_sinks) {
            std::printf("  error: sink 0x%03x not written this pass\n", csp::sink_base + stale);
            status = 1;
        }
    }
    if (dump) {
        for (int address = 0; address < csp::register_count; ++address) std::printf("%03x %05x\n", address, processor.read(address) & 0x3FFFF);
    }
    return status;
}

// A register write for the chip's load, "address=raw" (both in any base C understands).
struct RawWrite {
    int address;
    int32_t raw;
};

bool parse_write(const std::string &text, RawWrite &write) {
    const size_t equals = text.find('=');
    if (equals == std::string::npos) return false;
    write.address = static_cast<int>(std::strtol(text.substr(0, equals).c_str(), nullptr, 0));
    write.raw     = static_cast<int32_t>(std::strtol(text.substr(equals + 1).c_str(), nullptr, 0));
    return true;
}

// The firmware's csp-burst pattern: every register but the inputs, from a seed.
constexpr int no_fill = -1;

int32_t fill_value(int address, int seed) {
    return static_cast<int32_t>(csp::sign_extend((static_cast<int64_t>(address) * 37 + seed) & 0x1FFFF, csp::word_bits));
}

// `csp script`: the console commands that put the program and its registers on the chip.
int script_command(const csp::Program &program, int fill, const std::vector<RawWrite> &writes) {
    const csp::Image &image = program.image;
    std::printf("csp-hold\n");
    if (fill != no_fill) std::printf("csp-burst 1 %d %d\n", csp::register_count - 1, fill);
    for (int row = 0; row < image.rom_used; ++row) std::printf("csp-rom %d %05x\n", row, image.rom[static_cast<size_t>(row)]);
    for (int row = 0; row < image.length; ++row) {
        const csp::Row &bits = image.rows[static_cast<size_t>(row)];
        std::printf("csp-row %d %09llx %09llx\n", row, static_cast<unsigned long long>(bits.high),
                    static_cast<unsigned long long>(bits.low));
    }
    for (const RawWrite &write : writes) std::printf("csp-const %d %d\n", write.address, write.raw);
    std::printf("csp-go\n");
    return 0;
}

// `csp match`: the chip's registers against the model's, after the same load and as many
// passes as the chip ran. chip.txt holds csp-peek's lines, "  aaa: hhhhh (d)   aaa: hhhhh (d) ...".
int match_command(const csp::Program &program, const std::string &chip_path, int fill, const std::vector<RawWrite> &writes) {
    std::ifstream in(chip_path);
    if (!in) {
        std::fprintf(stderr, "cannot read %s\n", chip_path.c_str());
        return 2;
    }
    std::vector<int32_t> chip(csp::register_count, 0);
    std::vector<bool> seen(csp::register_count, false);
    std::string line;
    while (std::getline(in, line)) {
        size_t at = 0;
        while ((at = line.find(':', at)) != std::string::npos) {
            // "aaa: hhhhh" : the address is the hex word before the colon, the value the hex word after
            size_t start = at;
            while (start > 0 && std::isxdigit(static_cast<unsigned char>(line[start - 1]))) --start;
            const std::string address_text = line.substr(start, at - start);
            size_t value_start = at + 1;
            while (value_start < line.size() && line[value_start] == ' ') ++value_start;
            size_t value_end = value_start;
            while (value_end < line.size() && std::isxdigit(static_cast<unsigned char>(line[value_end]))) ++value_end;
            if (!address_text.empty() && value_end > value_start) {
                const int address = static_cast<int>(std::strtol(address_text.c_str(), nullptr, 16));
                const int64_t raw = std::strtol(line.substr(value_start, value_end - value_start).c_str(), nullptr, 16);
                if (address >= 0 && address < csp::register_count) {
                    chip[static_cast<size_t>(address)] = static_cast<int32_t>(csp::sign_extend(raw, csp::word_bits));
                    seen[static_cast<size_t>(address)] = true;
                }
            }
            at = value_end;
        }
    }
    csp::Processor model;
    model.load(program.image);
    if (fill != no_fill) {
        for (int address = 1; address < csp::register_count; ++address) {
            if (address >= csp::io_base && address < csp::io_base + csp::io_count) continue;
            model.write(address, fill_value(address, fill));
        }
    }
    for (const RawWrite &write : writes) model.write(write.address, write.raw);
    model.swap();
    while (model.queued_writes() > 0) model.pass();   // held: the window applies the writes
    model.release();
    // The passes the chip ran: every check program counts them in RUN_COUNT (0x3FE, wrapping) from
    // the fill's value, which the model holds too.
    constexpr int run_count = 0x3FE;
    if (!seen[run_count]) {
        std::printf("the chip's registers hold no RUN_COUNT (0x3fe)\n");
        return 2;
    }
    const int passes = static_cast<int>((static_cast<int64_t>(chip[run_count]) - model.read(run_count)) & 0x3FFFF);
    for (int pass = 0; pass < passes; ++pass) {
        const csp::PassReport report = model.pass();
        if (!report.errors.empty()) {
            std::printf("the model reports: %s\n", report.errors.front().c_str());
            return 1;
        }
    }
    std::printf("the chip ran %d passes\n", passes);
    int differing = 0;
    for (int address = 1; address < csp::register_count; ++address) {
        if (!seen[static_cast<size_t>(address)]) continue;
        if (address >= csp::io_base && address < csp::io_base + csp::io_count) continue;   // inputs: the chip's own
        if (chip[static_cast<size_t>(address)] != model.read(address)) {
            if (differing < 40) {
                std::printf("  %03x: chip %d (%05x), model %d (%05x)\n", address, chip[static_cast<size_t>(address)],
                            chip[static_cast<size_t>(address)] & 0x3FFFF, model.read(address), model.read(address) & 0x3FFFF);
            }
            ++differing;
        }
    }
    std::printf("%d register(s) differ\n", differing);
    return differing == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) return usage();
    const std::string command = argv[1];
    // the program: every leading argument that is a file, joined
    Sources sources;
    int arg = 2;
    for (; arg < argc && argv[arg][0] != '-'; ++arg) {
        std::string text;
        if (!read_file(argv[arg], text)) {
            std::fprintf(stderr, "cannot read %s\n", argv[arg]);
            return 2;
        }
        const int first_line = 1 + static_cast<int>(std::ranges::count(sources.text, '\n'));
        sources.parts.push_back({argv[arg], first_line});
        sources.text += text;
        if (!text.empty() && text.back() != '\n') sources.text += '\n';
    }
    if (sources.parts.empty()) return usage();
    const csp::Program program = csp::assemble(sources.text);
    if (!report(sources, program)) return 1;
    if (command == "asm") return assemble_command(program);
    if (command == "header") {
        std::vector<std::string> files;
        for (const Sources::Part &part : sources.parts) files.push_back(part.path);
        std::string name_space = "control";
        for (; arg + 1 < argc; arg += 2) {
            if (std::string(argv[arg]) == "-n") name_space = argv[arg + 1];
        }
        return header_command(program, files, name_space);
    }
    if (command == "script" || command == "match") {
        std::vector<RawWrite> writes;
        std::string chip_path;
        int fill = no_fill;
        for (; arg + 1 < argc; arg += 2) {
            const std::string option = argv[arg];
            RawWrite write{};
            if (option == "-w" && parse_write(argv[arg + 1], write)) writes.push_back(write);
            else if (option == "-c") chip_path = argv[arg + 1];
            else if (option == "-f") fill = std::atoi(argv[arg + 1]);
            else return usage();
        }
        if (command == "script") return script_command(program, fill, writes);
        if (chip_path.empty()) return usage();
        return match_command(program, chip_path, fill, writes);
    }
    if (command != "sim") return usage();

    int passes = 4;
    bool dump  = false;
    std::vector<std::string> watch;
    std::vector<ScriptedWrite> writes;
    for (; arg < argc; ++arg) {
        const std::string option = argv[arg];
        if (option == "-d") {
            dump = true;
            continue;
        }
        if (arg + 1 >= argc) return usage();
        const std::string value = argv[++arg];
        if (option == "-n") {
            passes = std::atoi(value.c_str());
        } else if (option == "-w") {
            if (!program.symbols.contains(value)) {
                std::fprintf(stderr, "unknown name %s\n", value.c_str());
                return 2;
            }
            watch.push_back(value);
        } else if (option == "-s") {
            const size_t equals = value.find('=');
            const size_t at     = value.find('@');
            if (equals == std::string::npos || at == std::string::npos || at < equals) return usage();
            const std::string name = value.substr(0, equals);
            if (!program.symbols.contains(name)) {
                std::fprintf(stderr, "unknown name %s\n", name.c_str());
                return 2;
            }
            writes.push_back({program.symbols.at(name), std::atoi(value.substr(equals + 1, at - equals - 1).c_str()),
                              std::atoi(value.substr(at + 1).c_str())});
        } else {
            return usage();
        }
    }
    return simulate_command(program, passes, watch, writes, dump);
}
