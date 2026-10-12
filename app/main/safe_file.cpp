// safe_file.cpp — saving text files so a power loss cannot tear them
// (see safe_file.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "safe_file.hpp"

#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace safe_file {

namespace {

constexpr std::string_view end_line =
        "# end\n"; // the last line of a complete .new file
constexpr std::string_view new_suffix = ".new";

bool ends_with(const std::string &s, std::string_view tail) {
    return s.size() >= tail.size()
           && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

// Whether a .new file is complete: it ends with end_line.
bool complete(const std::string &path) {
    FILE *in = std::fopen(path.c_str(), "rb");
    if (!in) {
        return false;
    }
    char tail[end_line.size()];
    long n  = static_cast<long>(end_line.size());
    bool ok = std::fseek(in, -n, SEEK_END) == 0
              && std::fread(tail, 1, end_line.size(), in) == end_line.size()
              && std::string_view(tail, end_line.size()) == end_line;
    std::fclose(in);
    return ok;
}

} // namespace

bool save(const std::string &path, const std::string &text,
          std::string &error) {
    const std::string tmp = path + std::string(new_suffix);
    FILE *out             = std::fopen(tmp.c_str(), "w");
    if (!out) {
        error = "cannot create " + tmp;
        return false;
    }
    bool ok = std::fwrite(text.data(), 1, text.size(), out) == text.size()
              && std::fwrite(end_line.data(), 1, end_line.size(), out)
                         == end_line.size()
              && std::fflush(out) == 0 && fsync(fileno(out)) == 0;
    ok = std::fclose(out) == 0 && ok;
    if (!ok) {
        std::remove(tmp.c_str());
        error = "cannot write " + tmp + " (storage full?)";
        return false;
    }
    std::remove(path.c_str()); // absent for a new file
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        error = "cannot rename " + tmp;
        return false;
    }
    return true;
}

int recover(const std::string &dir) {
    DIR *d = opendir(dir.c_str());
    if (!d) {
        return 0;
    }
    int repaired = 0;
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') {
            continue;
        }
        const std::string path = dir + "/" + e->d_name;
        struct stat st;
        if (stat(path.c_str(), &st) != 0) {
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            repaired += recover(path);
            continue;
        }
        if (!ends_with(path, new_suffix)) {
            continue;
        }
        if (complete(path)) { // finish the save
            const std::string target =
                    path.substr(0, path.size() - new_suffix.size());
            std::remove(target.c_str());
            std::rename(path.c_str(), target.c_str());
        } else { // undo it: the old file stays
            std::remove(path.c_str());
        }
        repaired++;
    }
    closedir(d);
    return repaired;
}

} // namespace safe_file
