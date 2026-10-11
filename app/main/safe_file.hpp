// safe_file.hpp — saving text files so a power loss cannot tear them
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// docs/storage_format.md "Saving": a file is written to <path>.new ending
// with the line "# end", flushed to the medium, then <path> is deleted
// and the .new file renamed into place. recover() runs at mount: a
// complete .new file (it ends with "# end") finishes its save, an
// incomplete one is deleted. The "# end" line is what tells them apart:
// a file cut off on a line boundary can still be valid TOML.
//
// Plain C++ with stdio and POSIX: the host tests use it too.

#pragma once

#include <string>

namespace safe_file {

// Save text to path the safe way. False, with the reason in error,
// if it could not be written.
bool save(const std::string &path, const std::string &text, std::string &error);

// Finish or undo interrupted saves under dir, recursively. Returns the
// number of files repaired.
int recover(const std::string &dir);

} // namespace safe_file
