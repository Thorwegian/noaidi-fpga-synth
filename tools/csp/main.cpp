// main.cpp — `csp`, the CSP assembler and simulator on the host
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   csp asm program.s
//       assemble; print each instruction word (36 bits, hex) with its
//       source line, then the constant registers the firmware writes
//   csp sim program.s [-n passes] [-w name]... [-s name=value@pass]...
//       assemble and run on the reference model: load the constants and
//       the program with the CSP held, release it, run `passes` passes
//       (default 4) and print the watched registers after each. -s queues
//       a firmware write (raw value) and swaps before the given pass.
//
// Diagnostics go to stderr as file:line: error|warning: message; the
// exit status is 1 if there was an error.

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "assembler.hpp"
#include "processor.hpp"

namespace {

int usage() {
    std::fputs(
            "usage: csp asm program.s\n"
            "       csp sim program.s [-n passes] [-w name]... [-s name=value@pass]...\n",
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

bool report(const std::string &path, const csp::Program &program) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::fprintf(stderr, "%s:%d: %s: %s\n", path.c_str(), d.line,
                     d.error ? "error" : "warning", d.message.c_str());
    }
    return program.ok();
}

int assemble_command(const csp::Program &program) {
    for (size_t at = 0; at < program.words.size(); ++at) {
        std::printf("%04zx  %09llx  ; line %d\n", at,
                    static_cast<unsigned long long>(program.words[at]),
                    program.source_lines[at]);
    }
    for (const csp::ConstantWrite &constant : program.constants) {
        std::printf("const 0x%03x = %d  (%.6f)\n", constant.address,
                    constant.raw,
                    static_cast<double>(constant.raw) / csp::word_one);
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
                     const std::vector<ScriptedWrite> &writes) {
    csp::Processor processor;
    for (const csp::ConstantWrite &constant : program.constants) {
        processor.write(constant.address, constant.raw);
    }
    processor.swap();
    processor.pass(); // held: applies the constants
    processor.load(program.words);
    processor.release();

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
            const int address = program.symbols.at(name);
            std::printf("  %s=%d", name.c_str(), processor.read(address));
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
    return status;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        return usage();
    }
    const std::string command = argv[1];
    const std::string path    = argv[2];
    std::string source;
    if (!read_file(path, source)) {
        std::fprintf(stderr, "cannot read %s\n", path.c_str());
        return 2;
    }
    const csp::Program program = csp::assemble(source);
    if (!report(path, program)) {
        return 1;
    }
    if (command == "asm") {
        return assemble_command(program);
    }
    if (command != "sim") {
        return usage();
    }

    int passes = 4;
    std::vector<std::string> watch;
    std::vector<ScriptedWrite> writes;
    for (int arg = 3; arg < argc; ++arg) {
        const std::string option = argv[arg];
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
    return simulate_command(program, passes, watch, writes);
}
