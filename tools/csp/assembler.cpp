// assembler.cpp — the CSP macro assembler (see assembler.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A text front end to csp::ProgramBuilder (app/main/csp), which the
// firmware's generator uses directly: this file parses and names, the
// builder checks, schedules and encodes. One pass over the source; names
// must be defined before use, except labels, which a LOOP or SKIP may
// name before they appear.

#include "assembler.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <optional>

namespace csp {

namespace {

// ---- text -----------------------------------------------------------------

std::string_view trim(std::string_view text) {
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) text.remove_prefix(1);
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) text.remove_suffix(1);
    return text;
}

std::string upper(std::string_view text) {
    std::string result(text);
    for (char &c : result) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return result;
}

bool is_identifier(std::string_view text) {
    if (text.empty() || !(std::isalpha(static_cast<unsigned char>(text[0])) || text[0] == '_')) return false;
    return std::ranges::all_of(text, [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_'; });
}

std::vector<std::string_view> split_operands(std::string_view text) {
    std::vector<std::string_view> operands;
    text = trim(text);
    if (text.empty()) return operands;
    size_t start = 0;
    while (true) {
        const size_t comma = text.find(',', start);
        operands.push_back(trim(text.substr(start, comma - start)));
        if (comma == std::string_view::npos) break;
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
    if (text.empty()) return std::nullopt;
    int base = 10;
    if (text.size() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        base = 16;
        text.remove_prefix(2);
    }
    const std::string digits(text);
    char *end             = nullptr;
    const long long value = std::strtoll(digits.c_str(), &end, base);
    if (end != digits.c_str() + digits.size()) return std::nullopt;
    return negative ? -value : value;
}

std::optional<double> parse_real(std::string_view text) {
    const std::string digits(trim(text));
    if (digits.empty()) return std::nullopt;
    char *end          = nullptr;
    const double value = std::strtod(digits.c_str(), &end);
    if (end != digits.c_str() + digits.size()) return std::nullopt;
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
    std::optional<int32_t> immediate_value(std::string_view text);
    std::optional<Source> source(std::string_view text);
    std::optional<Operand> result(std::string_view text);
    std::optional<ASource> a_operand(std::string_view text, const Operand &result);
    bool define(const std::string &name, SymbolKind kind, int64_t value);
    void close_at_end(size_t at, std::string_view end, bool is_loop);

    void error(std::string message) {
        program_.diagnostics.push_back({line_, true, std::move(message)});
    }

    Program program_;
    ProgramBuilder builder_;
    std::map<std::string, Symbol> symbols_;
    std::optional<std::string> block_;
    int64_t block_offset_ = 0;
    std::vector<ForwardEnd> forward_ends_;
    std::vector<int> emitted_lines_;   // each emitted instruction's line
    int line_ = 0;
};

Program Assembler::run(std::string_view source) {
    define("ZERO", SymbolKind::reg, 0);
    size_t start = 0;
    while (start <= source.size()) {
        const size_t end = source.find('\n', start);
        ++line_;
        statement(source.substr(start, end - start));
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    if (block_) {
        error(".block " + *block_ + " has no .end");
    }
    for (const ForwardEnd &forward : forward_ends_) {
        line_            = forward.line;
        const auto label = symbols_.find(forward.label);
        if (label == symbols_.end() || label->second.kind != SymbolKind::label) {
            error("unknown label " + forward.label);
            continue;
        }
        const auto end = static_cast<size_t>(label->second.value);
        if (forward.is_loop) builder_.close_loop(forward.at, end);
        else builder_.close_skip(forward.at, end);
    }

    const ProgramBuilder::Built built = builder_.build();
    for (const BuildIssue &found : built.issues) {
        const int line = found.at < emitted_lines_.size() ? emitted_lines_[found.at] : line_;
        program_.diagnostics.push_back({line, found.error, found.message});
    }
    std::ranges::stable_sort(program_.diagnostics, {}, &Diagnostic::line);
    program_.ok     = built.ok && std::ranges::none_of(program_.diagnostics, [](const Diagnostic &d) { return d.error; });
    program_.image  = built.image;
    program_.cycles = built.cycles;
    if (program_.ok) {
        program_.source_lines.assign(static_cast<size_t>(built.image.length), 0);
        for (size_t at = 0; at < built.position.size(); ++at) {
            if (built.position[at] < program_.source_lines.size()) {
                program_.source_lines[built.position[at]] = emitted_lines_[at];
            }
        }
    }
    for (const auto &[name, symbol] : symbols_) {
        program_.symbols[name] = static_cast<int>(symbol.value);
    }
    return std::move(program_);
}

void Assembler::statement(std::string_view text) {
    const size_t comment = text.find(';');
    if (comment != std::string_view::npos) text = text.substr(0, comment);
    text               = trim(text);
    const size_t colon = text.find(':');
    if (colon != std::string_view::npos && is_identifier(trim(text.substr(0, colon)))) {
        define(std::string(trim(text.substr(0, colon))), SymbolKind::label, static_cast<int64_t>(builder_.size()));
        text = trim(text.substr(colon + 1));
    }
    if (text.empty()) return;
    size_t space = 0;
    while (space < text.size() && !std::isspace(static_cast<unsigned char>(text[space]))) ++space;
    const std::string name          = upper(text.substr(0, space));
    const std::string_view operands = text.substr(space);
    if (name.front() == '.') directive(name, operands);
    else instruction(name, operands);
}

bool Assembler::define(const std::string &name, SymbolKind kind, int64_t value) {
    if (!symbols_.emplace(name, Symbol{kind, value}).second) {
        error(name + " is already defined");
        return false;
    }
    return true;
}

// Record this line as the source of every instruction the builder just emitted.
void Assembler::note_lines() {
    emitted_lines_.resize(builder_.size(), line_);
}

// ---- values and operands ----------------------------------------------------

// A number, or the value of a `.equ`, `.field` or `.const` name.
std::optional<int64_t> Assembler::number(std::string_view text) {
    text = trim(text);
    if (const auto value = parse_integer(text)) return value;
    const auto symbol = symbols_.find(std::string(text));
    if (symbol != symbols_.end()
        && (symbol->second.kind == SymbolKind::number || symbol->second.kind == SymbolKind::constant)) {
        return symbol->second.value;
    }
    error("not a number: " + std::string(text));
    return std::nullopt;
}

// An immediate's raw value: `#n` raw (a number or a name), else a real in
// Q4.14, rounded to the nearest raw step.
std::optional<int32_t> Assembler::immediate_value(std::string_view text) {
    text        = trim(text);
    int64_t raw = 0;
    if (!text.empty() && text[0] == '#') {
        const auto value = number(text.substr(1));
        if (!value) return std::nullopt;
        raw = *value;
    } else if (const auto symbol = symbols_.find(std::string(text));
               symbol != symbols_.end() && symbol->second.kind == SymbolKind::constant) {
        raw = symbol->second.value;
    } else {
        const auto value = parse_real(text);
        if (!value) {
            error("not a number: " + std::string(text));
            return std::nullopt;
        }
        raw = std::llround(*value * word_one);
    }
    if (raw > largest(word_bits) || raw < smallest(word_bits)) {
        error("immediate " + std::string(text) + " does not fit in a word");
        return std::nullopt;
    }
    return static_cast<int32_t>(raw);
}

// A result operand: a register, direct or indexed.
std::optional<Operand> Assembler::result(std::string_view text) {
    const auto parsed = source(text);
    if (!parsed) return std::nullopt;
    if (parsed->operand.mode == Operand::Mode::immediate) {
        error("a result is a register, not an immediate: " + std::string(text));
        return std::nullopt;
    }
    return parsed->operand;
}

// A source operand: a register, direct or indexed, or an immediate.
std::optional<Source> Assembler::source(std::string_view text) {
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
        const char which = static_cast<char>(std::tolower(static_cast<unsigned char>(inside[0])));
        if (which != 'i' && which != 'j') {
            error("indexed operand must use i or j: " + std::string(text));
            return std::nullopt;
        }
        const IndexRegister index   = which == 'i' ? IndexRegister::i : IndexRegister::j;
        const std::string_view rest = trim(inside.substr(1));
        int64_t offset              = 0;
        if (!rest.empty()) {
            if (rest.front() != '+') {
                error("bad indexed operand: " + std::string(text));
                return std::nullopt;
            }
            const auto value = number(rest.substr(1));
            if (!value) return std::nullopt;
            offset = *value;
        }
        return Source::reg(Operand::indexed(index, static_cast<int>(offset)));
    }
    if (text.front() == '=') {
        const auto raw = immediate_value(text.substr(1));
        if (!raw) return std::nullopt;
        return Source::imm(*raw);
    }
    int64_t address = 0;
    if (const auto symbol = symbols_.find(std::string(text)); symbol != symbols_.end()) {
        switch (symbol->second.kind) {
        case SymbolKind::reg:
        case SymbolKind::wide:
            address = symbol->second.value;
            break;
        case SymbolKind::constant:
            return Source::imm(static_cast<int32_t>(symbol->second.value));
        default:
            error("not a register: " + std::string(text));
            return std::nullopt;
        }
    } else if ((text.front() == 'r' || text.front() == 'R') && text.size() > 1 && parse_integer(text.substr(1))) {
        address = *parse_integer(text.substr(1));
    } else if (const auto value = parse_integer(text)) {
        address = *value;
    } else {
        error("unknown register: " + std::string(text));
        return std::nullopt;
    }
    return Source::reg(Operand::direct(static_cast<int>(address)));
}

// The A operand: `0`, `acc`, or the R operand written again.
std::optional<ASource> Assembler::a_operand(std::string_view text, const Operand &result) {
    text = trim(text);
    if (text == "0") return ASource::zero;
    if (upper(text) == "ACC") return ASource::accumulator;
    const auto parsed = source(text);
    if (!parsed) return std::nullopt;
    if (!(parsed->operand == result)) {
        error("the A operand must be 0, acc or the R operand: " + std::string(text));
        return std::nullopt;
    }
    return ASource::result;
}

// A LOOP's length or a SKIP's count: a number, or a label naming the
// first instruction after the body or the skipped run.
void Assembler::close_at_end(size_t at, std::string_view end, bool is_loop) {
    end             = trim(end);
    size_t position = 0;
    if (const auto value = parse_integer(end)) {
        position = at + 1 + static_cast<size_t>(std::max<int64_t>(*value, 0));
    } else if (const auto symbol = symbols_.find(std::string(end));
               symbol != symbols_.end() && symbol->second.kind == SymbolKind::number) {
        position = at + 1 + static_cast<size_t>(std::max<int64_t>(symbol->second.value, 0));
    } else if (is_identifier(end)) {
        forward_ends_.push_back({at, std::string(end), is_loop, line_});
        return;
    } else {
        error("not a count or a label: " + std::string(end));
        return;
    }
    if (is_loop) builder_.close_loop(at, position);
    else builder_.close_skip(at, position);
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
            if (const auto value = number(operands[1])) define(std::string(operands[0]), SymbolKind::number, *value);
        }
    } else if (name == ".REG" || name == ".WIDE") {
        if (need(2)) {
            const auto address = number(operands[1]);
            if (!address) return;
            if (*address <= 0 || *address >= address_space) {
                error("register address outside 0x001-0xBFF");
                return;
            }
            if (name == ".WIDE" && *address % 2 != 0) {
                error("a wide register needs an even address");
                return;
            }
            define(std::string(operands[0]), name == ".WIDE" ? SymbolKind::wide : SymbolKind::reg, *address);
        }
    } else if (name == ".CONST") {
        if (need(2)) {
            if (const auto raw = immediate_value(operands[1])) define(std::string(operands[0]), SymbolKind::constant, *raw);
        }
    } else if (name == ".BLOCK") {
        if (need(1)) {
            if (block_) error(".block inside .block " + *block_);
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
            if (words && define(std::string(operands[0]), SymbolKind::number, block_offset_)) block_offset_ += *words;
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
            if (!position) return;
            if (*position < static_cast<int64_t>(builder_.size())) {
                error(".org moves backwards");
                return;
            }
            while (builder_.size() < static_cast<size_t>(*position)) builder_.nop();
            note_lines();
        }
    } else {
        error("unknown directive " + name);
    }
}

// ---- instructions -----------------------------------------------------------

void Assembler::instruction(const std::string &full_name, std::string_view text) {
    const auto operands      = split_operands(text);
    const size_t dot         = full_name.find('.');
    const std::string name   = full_name.substr(0, dot);
    const std::string suffix = dot == std::string::npos ? "" : full_name.substr(dot + 1);
    const bool is_wide       = suffix == "W";

    auto need = [&](size_t count) {
        if (operands.size() != count) {
            error(full_name + " takes " + std::to_string(count) + " operands");
            return false;
        }
        return true;
    };

    using Arithmetic = size_t (ProgramBuilder::*)(Operand, ASource, Source, Source, bool);
    static const std::map<std::string, std::pair<Arithmetic, bool>> arithmetic = {
            {"MAC", {&ProgramBuilder::mac, true}},
            {"MACW", {&ProgramBuilder::macw, true}},
            {"ADD3", {&ProgramBuilder::add3, true}}};
    using ThreeOperand = size_t (ProgramBuilder::*)(Operand, Source, Source);
    static const std::map<std::string, ThreeOperand> three_operand = {
            {"CMP", &ProgramBuilder::cmp}, {"MIN", &ProgramBuilder::min}, {"MAX", &ProgramBuilder::max}};
    static const std::map<std::string, Condition> conditions = {
            {"ALWAYS", Condition::always}, {"NEG", Condition::negative}, {"POS", Condition::positive},
            {"ZERO", Condition::zero},     {"NONZERO", Condition::nonzero}, {"OVF", Condition::overflow}};

    const bool takes_wide = arithmetic.contains(name) || name == "SHIFT";
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
            if (need(3)) {
                const auto r = result(operands[0]);
                const auto x = r ? source(operands[1]) : std::nullopt;
                const auto y = x ? source(operands[2]) : std::nullopt;
                if (y) (builder_.*forms->second.first)(*r, ASource::result, *x, *y, true);
            }
        } else if (need(4)) {
            const auto r = result(operands[0]);
            const auto a = r ? a_operand(operands[1], *r) : std::nullopt;
            const auto x = a ? source(operands[2]) : std::nullopt;
            const auto y = x ? source(operands[3]) : std::nullopt;
            if (y) (builder_.*forms->second.first)(*r, *a, *x, *y, false);
        }
    } else if (name == "ANDXOR") {
        if (need(4)) {
            const auto r = result(operands[0]);
            const auto a = r ? a_operand(operands[1], *r) : std::nullopt;
            const auto x = a ? source(operands[2]) : std::nullopt;
            const auto y = x ? source(operands[3]) : std::nullopt;
            if (y) builder_.andxor(*r, *a, *x, *y);
        }
    } else if (const auto three = three_operand.find(name); three != three_operand.end()) {
        if (need(3)) {
            const auto r = result(operands[0]);
            const auto x = r ? source(operands[1]) : std::nullopt;
            const auto y = x ? source(operands[2]) : std::nullopt;
            if (y) (builder_.*three->second)(*r, *x, *y);
        }
    } else if (name == "SEL") {
        // SEL R, X, Y chooses by N, as before; SEL.cond is the condition
        if (need(3)) {
            const auto r = result(operands[0]);
            const auto x = r ? source(operands[1]) : std::nullopt;
            const auto y = x ? source(operands[2]) : std::nullopt;
            if (y) builder_.sel(*r, Condition::negative, *x, *y);
        }
    } else if (name == "NOP") {
        if (need(0)) builder_.nop();
    } else if (name == "ACC") {
        if (need(3)) {
            const std::string a = upper(trim(operands[0]));
            if (a != "0" && a != "ACC") {
                error("ACC's A operand must be 0 or acc");
            } else {
                const auto x = source(operands[1]);
                const auto y = x ? source(operands[2]) : std::nullopt;
                if (y) builder_.acc(a == "0" ? ASource::zero : ASource::accumulator, *x, *y);
            }
        }
    } else if (name == "SHIFT") {
        if (is_wide) {
            if (need(2)) {
                const auto r = result(operands[0]);
                const auto y = r ? source(operands[1]) : std::nullopt;
                if (y) builder_.shift(*r, ASource::result, *y, true);
            }
        } else if (need(3)) {
            const auto r = result(operands[0]);
            const auto a = r ? a_operand(operands[1], *r) : std::nullopt;
            const auto y = a ? source(operands[2]) : std::nullopt;
            if (y) builder_.shift(*r, *a, *y, false);
        }
    } else if (name == "ABS") {
        if (need(2)) {
            const auto r = result(operands[0]);
            const auto x = r ? source(operands[1]) : std::nullopt;
            if (x) builder_.abs(*r, *x);
        }
    } else if (name == "IDX") {
        if (need(3)) {
            const std::string which = upper(trim(operands[0]));
            if (which != "I" && which != "J") {
                error("IDX sets i or j");
            } else {
                const auto x = source(operands[1]);
                const auto y = x ? source(operands[2]) : std::nullopt;
                if (y) builder_.idx(which == "J" ? IndexRegister::j : IndexRegister::i, *x, *y);
            }
        }
    } else if (name == "SKIP") {
        if (need(2)) {
            const auto condition = conditions.find(upper(trim(operands[0])));
            if (condition == conditions.end()) {
                error("unknown SKIP condition " + std::string(operands[0]));
            } else {
                const size_t at = builder_.open_skip(condition->second);
                close_at_end(at, operands[1], false);
            }
        }
    } else if (name == "LOOP") {
        // LOOP.i, LOOP.j; LOOP.vi, LOOP.vj for a vector loop. The count and
        // the stride are immediates: =#n, or a number.
        const bool vector = suffix == "VI" || suffix == "VJ";
        const char which  = suffix.empty() ? '\0' : suffix.back();
        if ((suffix.size() != 1 && !vector) || (which != 'I' && which != 'J')) {
            error("LOOP needs .i, .j, .vi or .vj");
        } else if (need(3)) {
            auto raw = [&](std::string_view text) -> std::optional<int64_t> {
                text = trim(text);
                if (!text.empty() && text[0] == '=') text.remove_prefix(1);
                if (!text.empty() && text[0] == '#') text.remove_prefix(1);
                return number(text);
            };
            const auto count  = raw(operands[1]);
            const auto stride = count ? raw(operands[2]) : std::nullopt;
            if (stride) {
                const size_t at = builder_.open_loop(which == 'J' ? IndexRegister::j : IndexRegister::i,
                                                     static_cast<int>(*count), static_cast<int>(*stride), vector);
                close_at_end(at, operands[0], true);
            }
        }
    } else {
        error("unknown instruction " + full_name);
    }
    note_lines();
}

} // namespace

Program assemble(std::string_view source) {
    return Assembler().run(source);
}

} // namespace csp
