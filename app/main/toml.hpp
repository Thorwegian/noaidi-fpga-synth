// toml.hpp — a small C++ view of tomlc17's parse tree
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// tomlc17 ships a C++ wrapper (tomlcpp.hpp), but it relies on exceptions,
// which the firmware builds without. This is the part we use, on the C
// API: a Document owns a parse result; a Value reads one node, giving
// std::nullopt where the node is missing or of another type.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "tomlc17.h"

namespace toml {

class Value {
public:
    Value() : datum_{} {}
    explicit Value(const toml_datum_t &datum) : datum_(datum) {}

    bool is_table() const {
        return datum_.type == TOML_TABLE;
    }
    bool is_array() const {
        return datum_.type == TOML_ARRAY;
    }

    std::optional<std::string_view> as_string() const {
        if (datum_.type != TOML_STRING) {
            return std::nullopt;
        }
        return std::string_view(datum_.u.str.ptr,
                                static_cast<size_t>(datum_.u.str.len));
    }
    std::optional<int64_t> as_int() const {
        if (datum_.type != TOML_INT64) {
            return std::nullopt;
        }
        return datum_.u.int64;
    }
    std::optional<double> as_real() const {
        if (datum_.type != TOML_FP64) {
            return std::nullopt;
        }
        return datum_.u.fp64;
    }

    // A key of this table.
    std::optional<Value> get(const char *key) const {
        if (!is_table()) {
            return std::nullopt;
        }
        toml_datum_t d = toml_get(datum_, key);
        if (d.type == TOML_UNKNOWN) {
            return std::nullopt;
        }
        return Value(d);
    }

    // The elements of this array; empty if it is not one.
    std::vector<Value> elements() const {
        std::vector<Value> out;
        if (is_array()) {
            for (int32_t i = 0; i < datum_.u.arr.size; i++) {
                out.emplace_back(datum_.u.arr.elem[i]);
            }
        }
        return out;
    }

    // The keys and values of this table; empty if it is not one.
    std::vector<std::pair<std::string_view, Value>> entries() const {
        std::vector<std::pair<std::string_view, Value>> out;
        if (is_table()) {
            for (int32_t i = 0; i < datum_.u.tab.size; i++) {
                out.emplace_back(std::string_view(datum_.u.tab.key[i],
                                                  static_cast<size_t>(
                                                          datum_.u.tab.len[i])),
                                 Value(datum_.u.tab.value[i]));
            }
        }
        return out;
    }

private:
    toml_datum_t datum_;
};

// A parsed document. Values read from it are valid while it lives.
class Document {
public:
    explicit Document(std::string_view text)
        : result_(toml_parse(text.data(), static_cast<int>(text.size()))) {}
    ~Document() {
        toml_free(result_);
    }
    Document(const Document &)            = delete;
    Document &operator=(const Document &) = delete;

    bool ok() const {
        return result_.ok;
    }
    const char *error() const {
        return result_.errmsg;
    }
    Value root() const {
        return Value(result_.toptab);
    }

private:
    toml_result_t result_;
};

} // namespace toml
