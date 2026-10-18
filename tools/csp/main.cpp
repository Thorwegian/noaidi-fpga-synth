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
//   csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]...
//       assemble and run on the reference model: load the program with the
//       CSP held, release it, run `passes` passes (default 4) and print the
//       watched registers after each. -s queues a firmware write (raw
//       value) and swaps before the given pass.
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
               "       csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]...\n"
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
        std::printf("rom %02x = %05x  unit %d writes %d a %d%s cond %d%s%s sub %d\n", row,
                    image.rom[static_cast<size_t>(row)], static_cast<int>(control.unit),
                    static_cast<int>(control.writes), static_cast<int>(control.a_source),
                    control.y_wide ? " wide-y" : "", static_cast<int>(control.cond), control.barrier ? " barrier" : "",
                    control.wrap ? " wrap" : "", control.sub);
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
                     const std::vector<ScriptedWrite> &writes) {
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
    return status;
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
    if (command != "sim") return usage();

    int passes = 4;
    std::vector<std::string> watch;
    std::vector<ScriptedWrite> writes;
    for (; arg < argc; ++arg) {
        const std::string option = argv[arg];
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
    return simulate_command(program, passes, watch, writes);
}
