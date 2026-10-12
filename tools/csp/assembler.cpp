// assembler.cpp — the CSP macro assembler (see assembler.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A text front end to csp::ProgramBuilder (app/main/csp), which the
// firmware uses directly: this file parses and names, the builder emits
// and checks. One pass over the source; names must be defined before
// use, except labels, which a LOOP or SKIP may name before they appear.

#include "assembler.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <optional>

#include "csp/csp.hpp"
#include "csp/program_builder.hpp"

namespace csp {

namespace {

// ---- text -----------------------------------------------------------------

std::string_view trim(std::string_view text) {
    while (!text.empty()
           && std::isspace(static_cast<unsigned char>(text.front()))) {
        text.remove_prefix(1);
    }
    while (!text.empty()
           && std::isspace(static_cast<unsigned char>(text.back()))) {
        text.remove_suffix(1);
    }
    return text;
}

std::string upper(std::string_view text) {
    std::string result(text);
    for (char &c : result) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return result;
}

bool is_identifier(std::string_view text) {
    if (text.empty()
        || !(std::isalpha(static_cast<unsigned char>(text[0]))
             || text[0] == '_')) {
        return false;
    }
    return std::ranges::all_of(text, [](char c) {
        return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
    });
}

std::vector<std::string_view> split_operands(std::string_view text) {
    std::vector<std::string_view> operands;
    text = trim(text);
    if (text.empty()) {
        return operands;
    }
    size_t start = 0;
    while (true) {
        const size_t comma = text.find(',', start);
        operands.push_back(trim(text.substr(start, comma - start)));
        if (comma == std::string_view::npos) {
            break;
        }
        start = comma + 1;
    }
    return operands;
}

std::optional<int64_t> parse_integer(std::string_view text) {
    text          = trim(text);
    bool negative = false;
    if (!text.empty() && (text[0] == '-' || text[0] == '+')) {
        negative = text[0] == '-';
        text.remove_prefix(1);
    }
    if (text.empty()) {
        return std::nullopt;
    }
    int base = 10;
    if (text.size() > 2 && text[0] == '0'
        && (text[1] == 'x' || text[1] == 'X')) {
        base = 16;
        text.remove_prefix(2);
    }
    const std::string digits(text);
    char *end             = nullptr;
    const long long value = std::strtoll(digits.c_str(), &end, base);
    if (end != digits.c_str() + digits.size()) {
        return std::nullopt;
    }
    return negative ? -value : value;
}

std::optional<double> parse_real(std::string_view text) {
    const std::string digits(trim(text));
    if (digits.empty()) {
        return std::nullopt;
    }
    char *end          = nullptr;
    const double value = std::strtod(digits.c_str(), &end);
    if (end != digits.c_str() + digits.size()) {
        return std::nullopt;
    }
    return value;
}

// ---- the assembler --------------------------------------------------------

enum class SymbolKind { number, reg, wide, constant, label };

struct Symbol {
    SymbolKind kind;
    int64_t value;
};

// A LOOP or SKIP whose end is a label further on.
struct ForwardEnd {
    size_t at;
    std::string label;
    bool is_loop;
    int line;
};

class Assembler {
public:
    Program run(std::string_view source);

private:
    void statement(std::string_view text);
    void directive(const std::string &name, std::string_view operands);
    void instruction(const std::string &name, std::string_view operands);
    void note_lines();

    std::optional<int64_t> number(std::string_view text);
    std::optional<int32_t> constant_value(std::string_view text);
    std::optional<int> constant_register(int32_t raw);
    std::optional<Operand> operand(std::string_view text);
    std::optional<ASelect> a_operand(std::string_view text,
                                     const Operand &result);
    bool define(const std::string &name, SymbolKind kind, int64_t value);
    void close_at_end(size_t at, std::string_view end, bool is_loop);

    void error(std::string message) {
        program_.diagnostics.push_back({line_, true, std::move(message)});
    }

    Program program_;
    ProgramBuilder builder_;
    std::map<std::string, Symbol> symbols_;
    std::map<int32_t, int> pool_; // constant value → register
    int next_constant_ = constant_base;
    std::optional<std::string> block_;
    int64_t block_offset_ = 0;
    std::vector<ForwardEnd> forward_ends_;
    int line_ = 0;
};

Program Assembler::run(std::string_view source) {
    define("ZERO", SymbolKind::reg, 0);
    size_t start = 0;
    while (start <= source.size()) {
        const size_t end = source.find('\n', start);
        ++line_;
        statement(source.substr(start, end - start));
        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }
    if (block_) {
        error(".block " + *block_ + " has no .end");
    }
    for (const ForwardEnd &forward : forward_ends_) {
        line_            = forward.line;
        const auto label = symbols_.find(forward.label);
        if (label == symbols_.end()
            || label->second.kind != SymbolKind::label) {
            error("unknown label " + forward.label);
            continue;
        }
        const auto end = static_cast<size_t>(label->second.value);
        if (forward.is_loop) {
            builder_.close_loop(forward.at, end);
        } else {
            builder_.close_skip(forward.at, end);
        }
    }

    program_.words = builder_.words();
    for (const BuildIssue &found : builder_.check()) {
        const int line = found.at < program_.source_lines.size()
                                 ? program_.source_lines[found.at]
                                 : line_;
        program_.diagnostics.push_back({line, found.error, found.message});
    }
    std::ranges::stable_sort(program_.diagnostics, {}, &Diagnostic::line);
    for (const auto &[name, symbol] : symbols_) {
        program_.symbols[name] = static_cast<int>(symbol.value);
    }
    return std::move(program_);
}

void Assembler::statement(std::string_view text) {
    const size_t comment = text.find(';');
    if (comment != std::string_view::npos) {
        text = text.substr(0, comment);
    }
    text               = trim(text);
    const size_t colon = text.find(':');
    if (colon != std::string_view::npos
        && is_identifier(trim(text.substr(0, colon)))) {
        define(std::string(trim(text.substr(0, colon))), SymbolKind::label,
               static_cast<int64_t>(builder_.size()));
        text = trim(text.substr(colon + 1));
    }
    if (text.empty()) {
        return;
    }
    size_t space = 0;
    while (space < text.size()
           && !std::isspace(static_cast<unsigned char>(text[space]))) {
        ++space;
    }
    const std::string name          = upper(text.substr(0, space));
    const std::string_view operands = text.substr(space);
    if (name.front() == '.') {
        directive(name, operands);
    } else {
        instruction(name, operands);
    }
}

bool Assembler::define(const std::string &name, SymbolKind kind,
                       int64_t value) {
    if (!symbols_.emplace(name, Symbol{kind, value}).second) {
        error(name + " is already defined");
        return false;
    }
    return true;
}

// Record this line as the source of every word the builder just emitted.
void Assembler::note_lines() {
    program_.source_lines.resize(builder_.size(), line_);
}

// ---- values and operands ----------------------------------------------------

// A number, or the value of a `.equ` or `.field` name.
std::optional<int64_t> Assembler::number(std::string_view text) {
    text = trim(text);
    if (const auto value = parse_integer(text)) {
        return value;
    }
    const auto symbol = symbols_.find(std::string(text));
    if (symbol != symbols_.end() && symbol->second.kind == SymbolKind::number) {
        return symbol->second.value;
    }
    error("not a number: " + std::string(text));
    return std::nullopt;
}

// A constant's raw value: `#n` raw (a number or `.equ` name), else a real
// in Q4.14, rounded to the nearest raw step.
std::optional<int32_t> Assembler::constant_value(std::string_view text) {
    text        = trim(text);
    int64_t raw = 0;
    if (!text.empty() && text[0] == '#') {
        const auto value = number(text.substr(1));
        if (!value) {
            return std::nullopt;
        }
        raw = *value;
    } else {
        const auto value = parse_real(text);
        if (!value) {
            error("not a number: " + std::string(text));
            return std::nullopt;
        }
        raw = std::llround(*value * word_one);
    }
    if (raw > largest(word_bits) || raw < smallest(word_bits)) {
        error("constant " + std::string(text) + " does not fit in a word");
        return std::nullopt;
    }
    return static_cast<int32_t>(raw);
}

// The constant register holding raw, allocated in the pool if new.
std::optional<int> Assembler::constant_register(int32_t raw) {
    if (const auto found = pool_.find(raw); found != pool_.end()) {
        return found->second;
    }
    if (next_constant_ >= constant_base + constant_count) {
        error("constant pool full (" + std::to_string(constant_count)
              + " registers)");
        return std::nullopt;
    }
    const int address = next_constant_++;
    pool_[raw]        = address;
    program_.constants.push_back({address, raw});
    return address;
}

std::optional<Operand> Assembler::operand(std::string_view text) {
    text = trim(text);
    if (text.empty()) {
        error("missing operand");
        return std::nullopt;
    }
    if (text.front() == '[') {
        if (text.back() != ']' || text.size() < 3) {
            error("bad indexed operand: " + std::string(text));
            return std::nullopt;
        }
        const std::string_view inside = trim(text.substr(1, text.size() - 2));
        const char which              = static_cast<char>(
                std::tolower(static_cast<unsigned char>(inside[0])));
        if (which != 'i' && which != 'j') {
            error("indexed operand must use i or j: " + std::string(text));
            return std::nullopt;
        }
        const IndexRegister index =
                which == 'i' ? IndexRegister::i : IndexRegister::j;
        const std::string_view rest = trim(inside.substr(1));
        int64_t offset              = 0;
        if (!rest.empty()) {
            if (rest.front() != '+') {
                error("bad indexed operand: " + std::string(text));
                return std::nullopt;
            }
            const auto value = number(rest.substr(1));
            if (!value) {
                return std::nullopt;
            }
            offset = *value;
        }
        return Operand::indexed(index, static_cast<int>(offset));
    }

    int64_t address = 0;
    if (text.front() == '=') {
        const auto raw = constant_value(text.substr(1));
        if (!raw) {
            return std::nullopt;
        }
        const auto reg = constant_register(*raw);
        if (!reg) {
            return std::nullopt;
        }
        address = *reg;
    } else if (const auto symbol = symbols_.find(std::string(text));
               symbol != symbols_.end()
               && (symbol->second.kind == SymbolKind::reg
                   || symbol->second.kind == SymbolKind::wide
                   || symbol->second.kind == SymbolKind::constant)) {
        address = symbol->second.value;
    } else if ((text.front() == 'r' || text.front() == 'R') && text.size() > 1
               && parse_integer(text.substr(1))) {
        address = *parse_integer(text.substr(1));
    } else if (const auto value = parse_integer(text)) {
        address = *value;
    } else {
        error("unknown register: " + std::string(text));
        return std::nullopt;
    }
    return Operand::direct(static_cast<int>(address));
}

// The A operand: `0`, `acc`, or the R operand written again.
std::optional<ASelect> Assembler::a_operand(std::string_view text,
                                            const Operand &result) {
    text = trim(text);
    if (text == "0") {
        return ASelect::zero;
    }
    if (upper(text) == "ACC") {
        return ASelect::accumulator;
    }
    const auto parsed = operand(text);
    if (!parsed) {
        return std::nullopt;
    }
    if (!(*parsed == result)) {
        error("the A operand must be 0, acc or the R operand: "
              + std::string(text));
        return std::nullopt;
    }
    return ASelect::result;
}

// A LOOP's length or a SKIP's count: a number, or a label naming the
// first instruction after the body or the skipped run.
void Assembler::close_at_end(size_t at, std::string_view end, bool is_loop) {
    end             = trim(end);
    size_t position = 0;
    if (const auto value = parse_integer(end)) {
        position = at + 1 + static_cast<size_t>(std::max<int64_t>(*value, 0));
    } else if (const auto symbol = symbols_.find(std::string(end));
               symbol != symbols_.end()
               && symbol->second.kind == SymbolKind::number) {
        position = at + 1
                   + static_cast<size_t>(
                           std::max<int64_t>(symbol->second.value, 0));
    } else if (is_identifier(end)) {
        forward_ends_.push_back({at, std::string(end), is_loop, line_});
        return;
    } else {
        error("not a count or a label: " + std::string(end));
        return;
    }
    if (is_loop) {
        builder_.close_loop(at, position);
    } else {
        builder_.close_skip(at, position);
    }
}

// ---- directives -------------------------------------------------------------

void Assembler::directive(const std::string &name, std::string_view text) {
    const auto operands = split_operands(text);
    auto need           = [&](size_t count) {
        if (operands.size() != count) {
            error(name + " takes " + std::to_string(count) + " operand(s)");
            return false;
        }
        return true;
    };

    if (name == ".EQU") {
        if (need(2)) {
            if (const auto value = number(operands[1])) {
                define(std::string(operands[0]), SymbolKind::number, *value);
            }
        }
    } else if (name == ".REG" || name == ".WIDE") {
        if (need(2)) {
            const auto address = number(operands[1]);
            if (!address) {
                return;
            }
            if (*address <= 0 || *address >= register_count) {
                error("register address outside 0x001-0x7FF");
                return;
            }
            if (name == ".WIDE" && *address % 2 != 0) {
                error("a wide register needs an even address");
                return;
            }
            define(std::string(operands[0]),
                   name == ".WIDE" ? SymbolKind::wide : SymbolKind::reg,
                   *address);
        }
    } else if (name == ".CONST") {
        if (need(2)) {
            const auto raw = constant_value(operands[1]);
            if (!raw) {
                return;
            }
            if (const auto reg = constant_register(*raw)) {
                define(std::string(operands[0]), SymbolKind::constant, *reg);
            }
        }
    } else if (name == ".BLOCK") {
        if (need(1)) {
            if (block_) {
                error(".block inside .block " + *block_);
            }
            block_        = std::string(operands[0]);
            block_offset_ = 0;
        }
    } else if (name == ".FIELD") {
        if (!block_) {
            error(".field outside a .block");
            return;
        }
        if (need(2)) {
            const auto words = number(operands[1]);
            if (words
                && define(std::string(operands[0]), SymbolKind::number,
                          block_offset_)) {
                block_offset_ += *words;
            }
        }
    } else if (name == ".END") {
        if (!block_) {
            error(".end without .block");
            return;
        }
        define(*block_ + "_SIZE", SymbolKind::number, block_offset_);
        block_.reset();
    } else if (name == ".ORG") {
        if (need(1)) {
            const auto position = number(operands[0]);
            if (!position) {
                return;
            }
            if (*position < static_cast<int64_t>(builder_.size())) {
                error(".org moves backwards");
                return;
            }
            builder_.pad_to(static_cast<size_t>(*position));
            program_.source_lines.resize(builder_.size(), 0);
        }
    } else {
        error("unknown directive " + name);
    }
}

// ---- instructions -----------------------------------------------------------

void Assembler::instruction(const std::string &full_name,
                            std::string_view text) {
    const auto operands    = split_operands(text);
    const size_t dot       = full_name.find('.');
    const std::string name = full_name.substr(0, dot);
    const std::string suffix =
            dot == std::string::npos ? "" : full_name.substr(dot + 1);
    const bool is_wide = suffix == "W";

    auto need = [&](size_t count) {
        if (operands.size() != count) {
            error(full_name + " takes " + std::to_string(count) + " operands");
            return false;
        }
        return true;
    };
    // Parse operands in order; all must succeed.
    auto parse = [&](std::initializer_list<size_t> positions,
                     std::vector<Operand> &out) {
        for (const size_t position : positions) {
            const auto parsed = operand(operands[position]);
            if (!parsed) {
                return false;
            }
            out.push_back(*parsed);
        }
        return true;
    };

    using Arithmetic =
            size_t (ProgramBuilder::*)(Operand, ASelect, Operand, Operand);
    using Wide = size_t (ProgramBuilder::*)(Operand, Operand, Operand);
    struct ArithmeticForms {
        Arithmetic word;
        Wide wide; // nullptr: no wide form
    };
    static const std::map<std::string, ArithmeticForms> arithmetic = {
            {"MAC", {&ProgramBuilder::mac, &ProgramBuilder::mac_wide}},
            {"MACW", {&ProgramBuilder::macw, &ProgramBuilder::macw_wide}},
            {"INTERP", {&ProgramBuilder::interp, &ProgramBuilder::interp_wide}},
            {"ADD3", {&ProgramBuilder::add3, &ProgramBuilder::add3_wide}},
            {"ANDXOR", {&ProgramBuilder::andxor, nullptr}}};
    using ThreeOperand = size_t (ProgramBuilder::*)(Operand, Operand, Operand);
    static const std::map<std::string, ThreeOperand> three_operand = {
            {"SEL", &ProgramBuilder::sel},
            {"CMP", &ProgramBuilder::cmp},
            {"MIN", &ProgramBuilder::min},
            {"MAX", &ProgramBuilder::max}};

    std::vector<Operand> parsed;
    const bool takes_wide = arithmetic.contains(name)
                                    ? arithmetic.at(name).wide != nullptr
                                    : name == "SHIFT";
    if (is_wide && !takes_wide) {
        error(name + " has no wide form");
        return;
    }
    if (!suffix.empty() && !is_wide && name != "LOOP") {
        error("unknown suffix ." + suffix + " on " + name);
        return;
    }

    if (const auto forms = arithmetic.find(name); forms != arithmetic.end()) {
        if (is_wide) {
            if (need(3) && parse({0, 1, 2}, parsed)) {
                (builder_.*forms->second.wide)(parsed[0], parsed[1], parsed[2]);
            }
        } else if (need(4) && parse({0}, parsed)) {
            const auto a = a_operand(operands[1], parsed[0]);
            if (a && parse({2, 3}, parsed)) {
                (builder_.*forms->second.word)(parsed[0], *a, parsed[1],
                                               parsed[2]);
            }
        }
    } else if (const auto three = three_operand.find(name);
               three != three_operand.end()) {
        if (need(3) && parse({0, 1, 2}, parsed)) {
            (builder_.*three->second)(parsed[0], parsed[1], parsed[2]);
        }
    } else if (name == "NOP") {
        if (need(0)) {
            builder_.nop();
        }
    } else if (name == "ACC") {
        if (need(3)) {
            const std::string a = upper(trim(operands[0]));
            if (a != "0" && a != "ACC") {
                error("ACC's A operand must be 0 or acc");
            } else if (parse({1, 2}, parsed)) {
                builder_.acc(a == "0" ? ASelect::zero : ASelect::accumulator,
                             parsed[0], parsed[1]);
            }
        }
    } else if (name == "SHIFT") {
        if (is_wide) {
            if (need(2) && parse({0, 1}, parsed)) {
                builder_.shift_wide(parsed[0], parsed[1]);
            }
        } else if (need(3) && parse({0}, parsed)) {
            const auto a = a_operand(operands[1], parsed[0]);
            if (a && parse({2}, parsed)) {
                builder_.shift(parsed[0], *a, parsed[1]);
            }
        }
    } else if (name == "ABS") {
        if (need(2) && parse({0, 1}, parsed)) {
            builder_.abs(parsed[0], parsed[1]);
        }
    } else if (name == "IDX") {
        if (need(3)) {
            const std::string which = upper(trim(operands[0]));
            if (which != "I" && which != "J") {
                error("IDX sets i or j");
            } else if (parse({1, 2}, parsed)) {
                builder_.idx(which == "J" ? IndexRegister::j : IndexRegister::i,
                             parsed[0], parsed[1]);
            }
        }
    } else if (name == "SKIP") {
        if (need(2)) {
            static const std::map<std::string, Condition> conditions = {
                    {"ALWAYS", Condition::always},
                    {"NEG", Condition::negative},
                    {"POS", Condition::positive},
                    {"ZERO", Condition::zero},
                    {"NONZERO", Condition::nonzero},
                    {"OVF", Condition::overflow}};
            const auto condition = conditions.find(upper(trim(operands[0])));
            if (condition == conditions.end()) {
                error("unknown SKIP condition " + std::string(operands[0]));
            } else {
                const size_t at = builder_.open_skip(condition->second);
                close_at_end(at, operands[1], false);
            }
        }
    } else if (name == "LOOP") {
        if (suffix != "I" && suffix != "J") {
            error("LOOP needs .i or .j");
        } else if (need(3) && parse({1, 2}, parsed)) {
            const size_t at = builder_.open_loop(
                    suffix == "J" ? IndexRegister::j : IndexRegister::i,
                    parsed[0], parsed[1]);
            close_at_end(at, operands[0], true);
        }
    } else {
        error("unknown instruction " + full_name);
    }
    note_lines();
}

} // namespace

bool Program::ok() const {
    return std::ranges::none_of(diagnostics, [](const Diagnostic &d) {
        return d.error;
    });
}

Program assemble(std::string_view source) {
    return Assembler().run(source);
}

} // namespace csp
