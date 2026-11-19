// main.cpp — `csp`, the CSP assembler and simulator on the host
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   csp asm program.s...
//       assemble; print each row (a qword as two dwords, hex) with
//       its source line, then the decode ROM's rows and the pass's cycles
//   csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]... [-d]
//       assemble and run on the reference model: load the program with the
//       CSP held, release it, run `passes` passes (default 4) and print the
//       watched registers after each. -s queues a firmware write (raw
//       value) and swaps before the given pass. -d dumps every register
//       after the last pass, "address value" a line, raw.
//   csp script program.s... [-f seed] [-w address=raw]...
//       assemble and print the firmware console's commands that load the
//       program on the chip: csp hold, the decode ROM's rows, the instruction
//       rows, the register writes given, csp go. -f first fills every
//       register but the inputs with the firmware's csp burst pattern,
//       (address × 37 + seed) & 0x1FFFF, so the chip and the model start
//       alike whatever the chip held. tools/lab/chip_check.py sends
//       the lines and reads the registers back.
//   csp match program.s... -c chip.txt [-f seed] [-w address=raw]...
//       the chip's registers (csp peek's lines, every pair) against the
//       model run from the same load for as many passes as the chip ran,
//       which the program counts in RUN_COUNT (0x3FE): the differing
//       registers, or none.
//
// Several program files are joined into one, in order.
//
// `--noaidi` in place of the program files of asm, image, script and match is
// the program the firmware runs: the synth of app/main/wiring.cpp, built by
// its graph. Its script and its match load a set-up with it (performance.hpp:
// a value for every source, every pointer and stage one the program can
// follow), and for them the program counts its passes as well, in a word of
// the graph's own choosing, which match knows. `--selftest` in the same place
// is the boot self-test the firmware builds (app/main/csp/selftest.cpp).
//
// Diagnostics go to stderr as file:line: error|warning: message; the exit
// status is 1 if there was an error, or if the model reported one.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "assembler.hpp"
#include "csp/selftest.hpp"
#include "performance.hpp"
#include "processor.hpp"
#include "wiring.hpp"

namespace {

int usage() {
    std::fputs(
            "usage: csp asm program.s...\n"
            "       csp image program.s... -o prefix     (prefix.imem.hex, prefix.rom.hex for $readmemh)\n"
            "       csp sim program.s... [-n passes] [-w name]... [-s name=value@pass]... [-d]\n"
            "       csp script program.s... [-f seed] [-w address=raw]...\n"
            "       csp match program.s... -c chip.txt [-f seed] [-w address=raw]...\n"
            "       (several program files are joined into one, in order;\n"
            "        --noaidi in their place for asm, image, script and match\n"
            "        is the program the firmware runs, --selftest its boot\n"
            "        self-test)\n",
            stderr);
    return 2;
}

bool read_file(const std::string &path, std::string &text) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
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
            if (candidate.first_line <= line) {
                part = &candidate;
            }
        }
        return part->path + ":" + std::to_string(line - part->first_line + 1);
    }
};

bool report(const Sources &sources, const csp::Program &program) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::fprintf(stderr, "%s: %s: %s\n", sources.where(d.line).c_str(),
                     d.error ? "error" : "warning", d.message.c_str());
    }
    return program.ok;
}

// A row's source line in a listing: a wait the scheduler laid has none, and
// neither has a row of a program that was built, not assembled.
constexpr int wait_row  = 0;
constexpr int built_row = -1;

int assemble_command(const csp::Program &program) {
    const csp::Image &image = program.image;
    for (int row = 0; row < image.length; ++row) {
        const int line = program.source_lines[static_cast<size_t>(row)];
        std::printf("%04x  %09llx %09llx  %-6s", row,
                    static_cast<unsigned long long>(
                            image.rows[static_cast<size_t>(row)].high),
                    static_cast<unsigned long long>(
                            image.rows[static_cast<size_t>(row)].low),
                    line == wait_row ? "wait" : "");
        if (line > 0) {
            std::printf(" ; line %d", line);
        }
        std::printf("\n");
    }
    for (int row = 0; row < image.rom_used; ++row) {
        const csp::Control control =
                csp::Control::decode(image.rom[static_cast<size_t>(row)]);
        std::printf(
                "rom %02x = %05x  unit %d writes %d a %d%s%s%s cond %d%s sub %d\n",
                row, image.rom[static_cast<size_t>(row)],
                static_cast<int>(control.unit),
                static_cast<int>(control.writes),
                static_cast<int>(control.a_source), control.reads_x ? " x" : "",
                control.reads_y ? " y" : "", control.y_wide ? " wide-y" : "",
                static_cast<int>(control.cond), control.wrap ? " wrap" : "",
                control.sub);
    }
    std::printf("%d rows, %d decode rows, %d cycles a pass\n", image.length,
                image.rom_used, program.cycles);
    return 0;
}

// The image as a bench loads it over the bus ($readmemh): <prefix>.imem.hex
// holds the row count, then two dwords a row, bits 71:36 first, in the
// order they are written to the IMEM region; <prefix>.rom.hex holds the
// count of rows used, then one control word a row.
int image_command(const csp::Program &program, const std::string &prefix) {
    const csp::Image &image = program.image;
    std::ofstream imem(prefix + ".imem.hex");
    std::ofstream rom(prefix + ".rom.hex");
    if (!imem || !rom) {
        std::fprintf(stderr, "cannot write %s.imem.hex / .rom.hex\n",
                     prefix.c_str());
        return 2;
    }
    imem << std::hex << image.length << '\n';
    for (int row = 0; row < image.length; ++row) {
        const csp::Row &bits = image.rows[static_cast<size_t>(row)];
        imem << std::setfill('0') << std::setw(9) << bits.high << '\n'
             << std::setfill('0') << std::setw(9) << bits.low << '\n';
    }
    rom << std::hex << image.rom_used << '\n';
    for (int row = 0; row < image.rom_used; ++row) {
        rom << std::setfill('0') << std::setw(9)
            << image.rom[static_cast<size_t>(row)] << '\n';
    }
    return 0;
}

struct ScriptedWrite {
    int address;
    int32_t raw;
    int before_pass;
};

int simulate_command(const csp::Program &program, int passes,
                     const std::vector<std::string> &watch,
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
        if (queued) {
            processor.swap();
        }
        const csp::PassReport report = processor.pass();
        std::printf("pass %d: %d cycles", pass, report.cycles);
        for (const std::string &name : watch) {
            std::printf("  %s=%d", name.c_str(),
                        processor.read(program.symbols.at(name)));
        }
        std::printf("\n");
        for (const std::string &error : report.errors) {
            std::printf("  error: %s\n", error.c_str());
            status = 1;
        }
        for (int stale : report.stale_sinks) {
            std::printf("  error: sink 0x%03x not written this pass\n",
                        csp::sink_base + stale);
            status = 1;
        }
    }
    if (dump) {
        for (int address = 0; address < csp::register_count; ++address) {
            std::printf("%03x %05x\n", address,
                        processor.read(address) & 0x3FFFF);
        }
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
    if (equals == std::string::npos) {
        return false;
    }
    write.address = static_cast<int>(
            std::strtol(text.substr(0, equals).c_str(), nullptr, 0));
    write.raw = static_cast<int32_t>(
            std::strtol(text.substr(equals + 1).c_str(), nullptr, 0));
    return true;
}

// The firmware's csp burst pattern: every register but the inputs, from a seed.
constexpr int no_fill = -1;

int32_t fill_value(int address, int seed) {
    return static_cast<int32_t>(csp::sign_extend(
            (static_cast<int64_t>(address) * 37 + seed) & 0x1FFFF,
            csp::word_bits));
}

// Where a check program counts its passes (RUN_COUNT, in every program of
// programs/checks; the boot self-test counts in the same register).
constexpr int assembled_run_count = 0x3FE;

// ---- the programs the firmware builds ------------------------------------------------
//
// A built image as `csp` takes a program: each row the builder's own, or a
// wait it laid.
csp::Program program_of(const csp::ProgramBuilder::Built &built) {
    csp::Program program;
    program.image  = built.image;
    program.ok     = built.ok;
    program.cycles = built.cycles;
    program.source_lines.assign(static_cast<size_t>(built.image.length),
                                wait_row);
    for (const size_t row : built.position) {
        program.source_lines[row] = built_row;
    }
    return program;
}

// The synth the firmware wires and the program its graph builds, as `csp`
// takes a program: the image, the register writes of its load and where it
// counts its passes. A program that counts its passes, for the chip check,
// has the one thing added to the firmware's graph: a sum onto its own delayed
// output of a word the load sets to one raw step, wrapping, so that it counts
// from whatever the fill left in its word. The graph keeps what a sink
// reads, so a spare word of the first voice's block of sinks reads the count.
struct Noaidi {
    csp::Program program;
    std::vector<RawWrite> writes;
    int run_count = 0;
};

constexpr int run_count_sink =
        wiring::voice_sink::base + wiring::voice_sink::block - 1;

bool build_noaidi(Noaidi &noaidi, bool counts_passes) {
    using Graph      = csp::DspGraph;
    const auto synth = std::make_unique<wiring::Synth>();
    const auto built = std::make_unique<csp::ProgramBuilder::Built>();
    wiring::wire(*synth);
    Graph &graph = synth->graph;
    Graph::Wire step, count;
    if (counts_passes) {
        step                      = graph.source();
        const Graph::Wire counted = graph.delay();
        count = graph.sum(counted, step, {}, Graph::Overflow::wrap);
        graph.connect(counted, count);
        graph.sink(run_count_sink, count);
    }
    if (!graph.build(*built)) {
        for (const Graph::Issue &issue : graph.issues()) {
            std::fprintf(stderr, "the Noaidi's graph: error: %s\n",
                         issue.message.c_str());
        }
        return false;
    }
    noaidi.program = program_of(*built);
    for (const performance::Write &write :
         performance::writes(*synth, performance::set_up(*synth))) {
        noaidi.writes.push_back({write.address, write.raw});
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        noaidi.writes.push_back({initial.address, initial.value});
    }
    if (counts_passes) {
        noaidi.writes.push_back({graph.address(step), 1});
        noaidi.run_count = graph.address(count);
    }
    return true;
}

// `csp script`: the console commands that put the program and its registers on the chip.
int script_command(const csp::Program &program, int fill,
                   const std::vector<RawWrite> &writes) {
    const csp::Image &image = program.image;
    std::printf("csp hold\n");
    if (fill != no_fill) {
        std::printf("csp burst 1 %d %d\n", csp::register_count - 1, fill);
    }
    for (int row = 0; row < image.rom_used; ++row) {
        std::printf("csp rom %d %05x\n", row,
                    image.rom[static_cast<size_t>(row)]);
    }
    for (int row = 0; row < image.length; ++row) {
        const csp::Row &bits = image.rows[static_cast<size_t>(row)];
        std::printf("csp row %d %09llx %09llx\n", row,
                    static_cast<unsigned long long>(bits.high),
                    static_cast<unsigned long long>(bits.low));
    }
    for (const RawWrite &write : writes) {
        std::printf("csp const %d %d\n", write.address, write.raw);
    }
    std::printf("csp go\n");
    return 0;
}

// `csp match`: the chip's registers against the model's, after the same load and as many
// passes as the chip ran, which the program counts in the register `run_count`. chip.txt holds
// csp peek's lines, "  aaa: hhhhh (d)   aaa: hhhhh (d) ...".
int match_command(const csp::Program &program, const std::string &chip_path,
                  int fill, const std::vector<RawWrite> &writes,
                  int run_count) {
    std::ifstream in(chip_path);
    if (!in) {
        std::fprintf(stderr, "cannot read %s\n", chip_path.c_str());
        return 2;
    }
    std::vector<int32_t> chip(csp::register_count, 0);
    std::vector<bool> seen(csp::register_count, false);
    // "# before the run: 040: hhhhh" (tools/lab/chip_check.py): the pass counter's register
    // as the first pass read it, the number the run before this one left there.
    constexpr int32_t no_value   = -1;
    int32_t pass_register_before = no_value;
    std::string line;
    while (std::getline(in, line)) {
        if (line.rfind("# before the run:", 0) == 0) {
            const size_t at = line.find("040: ");
            if (at != std::string::npos) {
                pass_register_before = static_cast<int32_t>(csp::sign_extend(
                        std::strtol(line.c_str() + at + 5, nullptr, 16),
                        csp::word_bits));
            }
            continue;
        }
        size_t at = 0;
        while ((at = line.find(':', at)) != std::string::npos) {
            // "aaa: hhhhh" : the address is the hex word before the colon, the value the hex word after
            size_t start = at;
            while (start > 0
                   && std::isxdigit(
                           static_cast<unsigned char>(line[start - 1]))) {
                --start;
            }
            const std::string address_text = line.substr(start, at - start);
            size_t value_start             = at + 1;
            while (value_start < line.size() && line[value_start] == ' ') {
                ++value_start;
            }
            size_t value_end = value_start;
            while (value_end < line.size()
                   && std::isxdigit(
                           static_cast<unsigned char>(line[value_end]))) {
                ++value_end;
            }
            if (!address_text.empty() && value_end > value_start) {
                const int address = static_cast<int>(
                        std::strtol(address_text.c_str(), nullptr, 16));
                const int64_t raw = std::strtol(
                        line.substr(value_start, value_end - value_start)
                                .c_str(),
                        nullptr, 16);
                if (address >= 0 && address < csp::register_count) {
                    chip[static_cast<size_t>(address)] = static_cast<int32_t>(
                            csp::sign_extend(raw, csp::word_bits));
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
            if (address >= csp::io_base
                && address < csp::io_base + csp::io_count) {
                continue;
            }
            model.write(address, fill_value(address, fill));
        }
    }
    for (const RawWrite &write : writes) {
        model.write(write.address, write.raw);
    }
    model.swap();
    while (model.queued_writes() > 0) {
        model.pass(); // held: the window applies the writes
    }
    model.release();
    // The passes the chip ran: the program counts them, wrapping, from the fill's value,
    // which the model holds too.
    if (!seen[static_cast<size_t>(run_count)]) {
        std::printf("the chip's registers hold no pass count (0x%03x)\n",
                    run_count);
        return 2;
    }
    const int passes = static_cast<int>(
            (static_cast<int64_t>(chip[run_count]) - model.read(run_count))
            & 0x3FFFF);
    // The pass counter: the chip's went on before this run. Its register in the dump is the
    // number of the pass after the last one that ran (held, csp_pass keeps it), so the count
    // when the run began follows, and the first pass read what the run before left there.
    if (seen[csp::io_base] && pass_register_before != no_value) {
        const int64_t last = static_cast<int64_t>(chip[csp::io_base]) & 0x3FFFF;
        model.set_pass_count(last - passes - 1);
        model.set_input(csp::io_base, pass_register_before);
    }
    for (int pass = 0; pass < passes; ++pass) {
        const csp::PassReport report = model.pass();
        if (!report.errors.empty()) {
            std::printf("the model reports: %s\n",
                        report.errors.front().c_str());
            return 1;
        }
    }
    std::printf("the chip ran %d passes\n", passes);
    int differing = 0;
    for (int address = 1; address < csp::register_count; ++address) {
        if (!seen[static_cast<size_t>(address)]) {
            continue;
        }
        if (address >= csp::io_base && address < csp::io_base + csp::io_count) {
            continue; // inputs: the chip's own
        }
        if (chip[static_cast<size_t>(address)] != model.read(address)) {
            if (differing < 40) {
                std::printf("  %03x: chip %d (%05x), model %d (%05x)\n",
                            address, chip[static_cast<size_t>(address)],
                            chip[static_cast<size_t>(address)] & 0x3FFFF,
                            model.read(address), model.read(address) & 0x3FFFF);
            }
            ++differing;
        }
    }
    std::printf("%d register(s) differ\n", differing);
    return differing == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        return usage();
    }
    const std::string command = argv[1];
    // the program: one the firmware builds, the Noaidi's or the boot
    // self-test, or every leading argument that is a file, joined and
    // assembled
    Sources sources;
    csp::Program program;
    std::vector<RawWrite> load_writes; // for script and match
    int run_count           = assembled_run_count;
    int arg                 = 2;
    const std::string first = argv[arg];
    if (first == "--noaidi" || first == "--selftest") {
        if (command != "asm" && command != "image" && command != "script"
            && command != "match") {
            return usage();
        }
        if (first == "--noaidi") {
            const bool chip_check = command == "script" || command == "match";
            const auto noaidi     = std::make_unique<Noaidi>();
            if (!build_noaidi(*noaidi, chip_check)) {
                return 1;
            }
            program     = noaidi->program;
            load_writes = noaidi->writes;
            run_count   = noaidi->run_count;
        } else {
            const auto built = std::make_unique<csp::ProgramBuilder::Built>();
            csp::selftest::build(*built);
            for (const csp::BuildIssue &issue : built->issues) {
                std::fprintf(stderr, "the boot self-test: %s: %s\n",
                             issue.error ? "error" : "warning",
                             issue.message.c_str());
            }
            if (!built->ok) {
                return 1;
            }
            program   = program_of(*built);
            run_count = csp::selftest::run_count;
        }
        ++arg;
    } else {
        for (; arg < argc && argv[arg][0] != '-'; ++arg) {
            std::string text;
            if (!read_file(argv[arg], text)) {
                std::fprintf(stderr, "cannot read %s\n", argv[arg]);
                return 2;
            }
            const int first_line =
                    1
                    + static_cast<int>(std::ranges::count(sources.text, '\n'));
            sources.parts.push_back({argv[arg], first_line});
            sources.text += text;
            if (!text.empty() && text.back() != '\n') {
                sources.text += '\n';
            }
        }
        if (sources.parts.empty()) {
            return usage();
        }
        program = csp::assemble(sources.text);
        if (!report(sources, program)) {
            return 1;
        }
    }
    if (command == "asm") {
        return assemble_command(program);
    }
    if (command == "image") {
        if (arg + 1 < argc && std::string(argv[arg]) == "-o") {
            return image_command(program, argv[arg + 1]);
        }
        return usage();
    }
    if (command == "script" || command == "match") {
        std::string chip_path;
        int fill = no_fill;
        for (; arg + 1 < argc; arg += 2) {
            const std::string option = argv[arg];
            RawWrite write{};
            if (option == "-w" && parse_write(argv[arg + 1], write)) {
                load_writes.push_back(write);
            } else if (option == "-c") {
                chip_path = argv[arg + 1];
            } else if (option == "-f") {
                fill = std::atoi(argv[arg + 1]);
            } else {
                return usage();
            }
        }
        if (command == "script") {
            return script_command(program, fill, load_writes);
        }
        if (chip_path.empty()) {
            return usage();
        }
        return match_command(program, chip_path, fill, load_writes, run_count);
    }
    if (command != "sim") {
        return usage();
    }

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
        if (arg + 1 >= argc) {
            return usage();
        }
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
            if (equals == std::string::npos || at == std::string::npos
                || at < equals) {
                return usage();
            }
            const std::string name = value.substr(0, equals);
            if (!program.symbols.contains(name)) {
                std::fprintf(stderr, "unknown name %s\n", name.c_str());
                return 2;
            }
            writes.push_back(
                    {program.symbols.at(name),
                     std::atoi(
                             value.substr(equals + 1, at - equals - 1).c_str()),
                     std::atoi(value.substr(at + 1).c_str())});
        } else {
            return usage();
        }
    }
    return simulate_command(program, passes, watch, writes, dump);
}
