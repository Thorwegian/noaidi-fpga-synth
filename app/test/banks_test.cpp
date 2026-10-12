// banks_test.cpp — host test: banks.toml reads, writes back exactly, and
// the factory banks file reads back exactly through the writer (a warning
// if its text is not in the writer's form)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   make fw-test

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#include "banks.hpp"

namespace {

int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL %s\n", what);
        failures++;
    }
}

std::string file_text(const char *path) {
    std::string text;
    if (FILE *in = std::fopen(path, "rb")) {
        char buf[512];
        size_t got;
        while ((got = std::fread(buf, 1, sizeof buf, in)) > 0) {
            text.append(buf, got);
        }
        std::fclose(in);
    }
    return text;
}

// The text without its whole-line comments.
std::string without_comment_lines(const std::string &text) {
    std::string out;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        end        = end == std::string::npos ? text.size() : end + 1;
        if (text[start] != '#') {
            out.append(text, start, end - start);
        }
        start = end;
    }
    return out;
}

} // namespace

int main(int argc, char **argv) {
    std::string error;

    // A map with the cases a writer has to get right: quotes and
    // backslashes, an empty bank, a sparse bank numbering.
    banks::BankMap map;
    map[0]     = {"Factory",
                  {"Patches/Factory/Pads/Supersaw.toml",
                   "Patches/Factory/Leads/RnB Whistle.toml"}};
    map[1]     = {"User", {}};
    map[16383] = {"Quote \" and back\\slash",
                  {"Patches/User/Pads/Arctic Ice.toml"}};
    banks::BankMap back;
    check(banks::parse(banks::to_text(map), back, error),
          "parse the writer's text");
    check(back.size() == map.size(), "bank count survives");
    for (const auto &[n, bank] : map) {
        check(back.count(n) && back[n].name == bank.name, "bank name survives");
        check(back.count(n) && back[n].programs == bank.programs,
              "bank programs survive");
    }
    check(banks::to_text(back) == banks::to_text(map),
          "writing again gives the same text");

    // Lookup.
    check(banks::program_path(map, 0, 1)
                  == "Patches/Factory/Leads/RnB Whistle.toml",
          "program 0.1");
    check(!banks::program_path(map, 0, 2), "no program 0.2");
    check(!banks::program_path(map, 2, 0), "no bank 2");
    check(!banks::program_path(map, 1, 0), "empty bank 1");

    // What the reader ignores.
    std::string odd =
            "format = 1\n"
            "[bank.x]\nname = \"not a number\"\n"
            "[bank.16384]\nname = \"too high\"\n"
            "[bank.5]\nname = \"five\"\nprograms = [\"a.toml\", 7, \"b.toml\"]\n";
    banks::BankMap odd_map;
    check(banks::parse(odd, odd_map, error), "parse odd keys");
    check(odd_map.size() == 1 && odd_map.count(5), "only bank 5 is kept");
    check(odd_map[5].programs == std::vector<std::string>{"a.toml", "b.toml"},
          "non-strings skipped");
    std::string many = "format = 1\n[bank.0]\nprograms = [";
    for (int i = 0; i < 130; i++) {
        many += "\"p.toml\",";
    }
    many += "]\n";
    banks::BankMap many_map;
    check(banks::parse(many, many_map, error)
                  && many_map[0].programs.size() == 128,
          "128 programs at most");
    check(!banks::parse("format = 2\n", odd_map, error),
          "a newer format is refused");

    // Saving, and a missing file.
    char dir[] = "/tmp/noaidi_banks_XXXXXX";
    check(mkdtemp(dir) != nullptr, "mkdtemp");
    std::string path = std::string(dir) + "/banks.toml";
    banks::BankMap empty;
    check(banks::read(path, empty, error) && empty.empty(),
          "a missing file is no banks");
    check(banks::save(path, map, error), "save");
    check(banks::read(path, back, error)
                  && banks::to_text(back) == banks::to_text(map),
          "saved file reads back");
    std::remove(path.c_str());
    rmdir(dir);

    // The factory banks file reads, and reads back exactly through the
    // writer. Text that differs from the writer's is formatting: a warning.
    for (int a = 1; a < argc; a++) {
        banks::BankMap factory;
        bool ok = banks::read(argv[a], factory, error);
        check(ok, argv[a]);
        if (!ok) {
            continue;
        }
        const std::string written = banks::to_text(factory);
        banks::BankMap reread;
        check(banks::parse(written, reread, error)
                      && banks::to_text(reread) == written,
              "the factory banks read back exactly through the writer");
        if (written != without_comment_lines(file_text(argv[a]))) {
            std::printf(
                    "WARN %s is not in the writer's form; the writer gives:\n%s",
                    argv[a], written.c_str());
        } else {
            std::printf("%s: reads back exactly\n", argv[a]);
        }
    }

    std::printf("banks: %s (%d failures)\n", failures ? "FAIL" : "ALL PASS",
                failures);
    return failures ? 1 : 0;
}
