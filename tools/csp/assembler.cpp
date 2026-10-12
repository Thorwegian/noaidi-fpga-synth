// assembler.cpp — the CSP assembler (see assembler.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One pass over the source builds the words; the checks that need the
// whole program (delay slots, loops, SKIP ranges, length) run after it.
// Names must be defined before they are used.

#include "assembler.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <optional>

#include "csp.hpp"

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

struct LoopRecord {
    size_t at;  // the LOOP instruction
    size_t end; // one past its body
    IndexRegister index;
    int line;
};

struct SkipRecord {
    size_t at;
    size_t count;
    int line;
};

class Assembler {
public:
    Program run(std::string_view source);

private:
    void statement(std::string_view text);
    void directive(const std::string &name, std::string_view operands);
    void instruction(const std::string &name, std::string_view operands);
    void emit(const Instruction &instruction);

    std::optional<int64_t> number(std::string_view text);
    std::optional<int32_t> constant_value(std::string_view text);
    std::optional<int> constant_register(int32_t raw);
    std::optional<Operand> operand(std::string_view text);
    std::optional<uint16_t> field(std::string_view text);
    std::optional<ASelect> a_operand(std::string_view text, uint16_t result);
    bool define(const std::string &name, SymbolKind kind, int64_t value);

    void check_delay_slots();
    void check_loops();
    void check_skips();

    void error(std::string message) {
        program_.diagnostics.push_back({line_, true, std::move(message)});
    }
    void warning(int line, std::string message) {
        program_.diagnostics.push_back({line, false, std::move(message)});
    }

    Program program_;
    std::map<std::string, Symbol> symbols_;
    std::map<int32_t, int> pool_; // constant value → register
    int next_constant_ = constant_base;
    std::optional<std::string> block_;
    int64_t block_offset_ = 0;
    std::vector<LoopRecord> loops_;
    std::vector<SkipRecord> skips_;
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
    if (program_.words.size() > max_program_length) {
        line_ = 0;
        error("program is " + std::to_string(program_.words.size())
              + " instructions; a pass holds "
              + std::to_string(max_program_length));
    }
    check_delay_slots();
    check_loops();
    check_skips();
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
               static_cast<int64_t>(program_.words.size()));
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
        std::string_view rest = trim(inside.substr(1));
        int64_t offset        = 0;
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
        if (offset < 0 || offset > 255) {
            error("index offset " + std::to_string(offset) + " outside 0–255");
            return std::nullopt;
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
    if (address < 0 || address >= direct_reach) {
        error("register 0x" + std::to_string(address)
              + " is beyond direct reach (0–511): use i or j");
        return std::nullopt;
    }
    return Operand::direct(static_cast<int>(address));
}

std::optional<uint16_t> Assembler::field(std::string_view text) {
    const auto parsed = operand(text);
    if (!parsed) {
        return std::nullopt;
    }
    return parsed->encode();
}

// The A operand: `0`, `acc`, or the R operand written again.
std::optional<ASelect> Assembler::a_operand(std::string_view text,
                                            uint16_t result) {
    text = trim(text);
    if (text == "0") {
        return ASelect::zero;
    }
    if (upper(text) == "ACC") {
        return ASelect::accumulator;
    }
    const auto parsed = field(text);
    if (!parsed) {
        return std::nullopt;
    }
    if (*parsed != result) {
        error("the A operand must be 0, acc or the R operand: "
              + std::string(text));
        return std::nullopt;
    }
    return ASelect::result;
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
                error("register address outside 0x001–0x7FF");
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
            if (*position < static_cast<int64_t>(program_.words.size())) {
                error(".org moves backwards");
                return;
            }
            while (static_cast<int64_t>(program_.words.size()) < *position) {
                program_.words.push_back(Instruction{}.encode());
                program_.source_lines.push_back(0);
            }
        }
    } else {
        error("unknown directive " + name);
    }
}

// ---- instructions -----------------------------------------------------------

void Assembler::emit(const Instruction &instruction) {
    program_.words.push_back(instruction.encode());
    program_.source_lines.push_back(line_);
}

void Assembler::instruction(const std::string &full_name,
                            std::string_view text) {
    const auto operands    = split_operands(text);
    const size_t dot       = full_name.find('.');
    const std::string name = full_name.substr(0, dot);
    const std::string suffix =
            dot == std::string::npos ? "" : full_name.substr(dot + 1);

    static const std::map<std::string, Opcode> opcodes = {
            {"NOP", Opcode::nop},       {"LOOP", Opcode::loop},
            {"MACW", Opcode::macw},     {"INTERP", Opcode::interp},
            {"ACC", Opcode::acc},       {"ADD3", Opcode::add3},
            {"SEL", Opcode::sel},       {"CMP", Opcode::cmp},
            {"MIN", Opcode::min},       {"MAX", Opcode::max},
            {"ANDXOR", Opcode::andxor}, {"SHIFT", Opcode::shift},
            {"MAC", Opcode::mac},       {"ABS", Opcode::abs},
            {"SKIP", Opcode::skip},     {"IDX", Opcode::idx}};
    const auto found = opcodes.find(name);
    if (found == opcodes.end()) {
        error("unknown instruction " + full_name);
        return;
    }
    Instruction ins;
    ins.op             = found->second;
    const bool is_wide = suffix == "W";
    if (is_wide && !has_wide_form(ins.op)) {
        error(name + " has no wide form");
        return;
    }
    if (!suffix.empty() && !is_wide && ins.op != Opcode::loop) {
        error("unknown suffix ." + suffix + " on " + name);
        return;
    }
    auto need = [&](size_t count) {
        if (operands.size() != count) {
            error(full_name + " takes " + std::to_string(count) + " operands");
            return false;
        }
        return true;
    };
    auto set = [&](uint16_t &target, std::string_view text) {
        const auto value = field(text);
        if (value) {
            target = *value;
        }
        return value.has_value();
    };

    switch (ins.op) {
    case Opcode::nop:
        if (!need(0)) {
            return;
        }
        break;

    case Opcode::mac:
    case Opcode::macw:
    case Opcode::interp:
    case Opcode::add3:
    case Opcode::andxor:
        if (is_wide) {
            if (!need(3) || !set(ins.r, operands[0]) || !set(ins.x, operands[1])
                || !set(ins.y, operands[2])) {
                return;
            }
            ins.a = ASelect::wide;
        } else {
            if (!need(4) || !set(ins.r, operands[0])) {
                return;
            }
            const auto a = a_operand(operands[1], ins.r);
            if (!a || !set(ins.x, operands[2]) || !set(ins.y, operands[3])) {
                return;
            }
            ins.a = *a;
        }
        break;

    case Opcode::acc: {
        if (!need(3)) {
            return;
        }
        const std::string a = upper(trim(operands[0]));
        if (a != "0" && a != "ACC") {
            error("ACC's A operand must be 0 or acc");
            return;
        }
        ins.a = a == "0" ? ASelect::zero : ASelect::accumulator;
        if (!set(ins.x, operands[1]) || !set(ins.y, operands[2])) {
            return;
        }
        break;
    }

    case Opcode::sel:
    case Opcode::cmp:
    case Opcode::min:
    case Opcode::max:
        if (!need(3) || !set(ins.r, operands[0]) || !set(ins.x, operands[1])
            || !set(ins.y, operands[2])) {
            return;
        }
        break;

    case Opcode::shift:
        if (is_wide) {
            if (!need(2) || !set(ins.r, operands[0])
                || !set(ins.y, operands[1])) {
                return;
            }
            ins.a = ASelect::wide;
        } else {
            if (!need(3) || !set(ins.r, operands[0])) {
                return;
            }
            const auto a = a_operand(operands[1], ins.r);
            if (!a || !set(ins.y, operands[2])) {
                return;
            }
            ins.a = *a;
        }
        break;

    case Opcode::abs:
        if (!need(2) || !set(ins.r, operands[0]) || !set(ins.x, operands[1])) {
            return;
        }
        break;

    case Opcode::skip: {
        if (!need(2)) {
            return;
        }
        static const std::map<std::string, Condition> conditions = {
                {"ALWAYS", Condition::always},   {"NEG", Condition::negative},
                {"POS", Condition::positive},    {"ZERO", Condition::zero},
                {"NONZERO", Condition::nonzero}, {"OVF", Condition::overflow}};
        const auto condition = conditions.find(upper(trim(operands[0])));
        if (condition == conditions.end()) {
            error("unknown SKIP condition " + std::string(operands[0]));
            return;
        }
        const auto count = number(operands[1]);
        if (!count) {
            return;
        }
        if (*count < 1 || *count > 1023) {
            error("SKIP count outside 1–1023");
            return;
        }
        ins.x = static_cast<uint16_t>(condition->second);
        ins.y = static_cast<uint16_t>(*count);
        skips_.push_back(
                {program_.words.size(), static_cast<size_t>(*count), line_});
        break;
    }

    case Opcode::idx: {
        if (!need(3)) {
            return;
        }
        const std::string which = upper(trim(operands[0]));
        if (which != "I" && which != "J") {
            error("IDX sets i or j");
            return;
        }
        ins.r = which == "J" ? 1 : 0;
        if (!set(ins.x, operands[1]) || !set(ins.y, operands[2])) {
            return;
        }
        break;
    }

    case Opcode::loop: {
        if (suffix != "I" && suffix != "J") {
            error("LOOP needs .i or .j");
            return;
        }
        if (!need(3)) {
            return;
        }
        const auto length = number(operands[0]);
        if (!length) {
            return;
        }
        if (*length < 1 || *length > 1023) {
            error("LOOP length outside 1–1023");
            return;
        }
        ins.r = static_cast<uint16_t>(*length);
        ins.a = suffix == "J" ? ASelect::result : ASelect::zero; // a bit 0
        if (!set(ins.x, operands[1]) || !set(ins.y, operands[2])) {
            return;
        }
        const size_t at = program_.words.size();
        loops_.push_back({at, at + 1 + static_cast<size_t>(*length),
                          suffix == "J" ? IndexRegister::j : IndexRegister::i,
                          line_});
        break;
    }
    }
    emit(ins);
}

// ---- whole-program checks -----------------------------------------------------

// Which of an instruction's fields are register operands.
struct OperandFields {
    bool r, x, y;
};

OperandFields operand_fields(Opcode op) {
    switch (op) {
    case Opcode::nop:
    case Opcode::skip:
        return {false, false, false};
    case Opcode::loop:
    case Opcode::idx:
    case Opcode::acc:
        return {false, true, true};
    case Opcode::abs:
        return {true, true, false};
    case Opcode::shift:
        return {true, false, true};
    default:
        return {true, true, true};
    }
}

void Assembler::check_delay_slots() {
    const auto &words = program_.words;
    for (size_t at = 0; at < words.size(); ++at) {
        const Instruction ins = Instruction::decode(words[at]);
        if (ins.op != Opcode::idx) {
            continue;
        }
        const auto target = (ins.r & 1) ? IndexRegister::j : IndexRegister::i;
        const char name   = target == IndexRegister::j ? 'j' : 'i';
        for (size_t later = at + 1;
             later <= at + index_delay && later < words.size(); ++later) {
            const Instruction next     = Instruction::decode(words[later]);
            const OperandFields fields = operand_fields(next.op);
            const bool uses =
                    (fields.r
                     && Operand::decode(next.r).mode == Operand::Mode::indexed
                     && Operand::decode(next.r).index == target)
                    || (fields.x
                        && Operand::decode(next.x).mode
                                   == Operand::Mode::indexed
                        && Operand::decode(next.x).index == target)
                    || (fields.y
                        && Operand::decode(next.y).mode
                                   == Operand::Mode::indexed
                        && Operand::decode(next.y).index == target);
            if (uses) {
                warning(program_.source_lines[later],
                        std::string("uses ") + name
                                + " in a delay slot of the IDX on line "
                                + std::to_string(program_.source_lines[at])
                                + ": it still sees the old value");
            }
        }
    }
}

void Assembler::check_loops() {
    for (const LoopRecord &loop : loops_) {
        line_ = loop.line;
        if (loop.end > program_.words.size()) {
            error("LOOP body runs past the end of the program");
        }
        int depth = 0;
        for (const LoopRecord &outer : loops_) {
            if (&outer == &loop) {
                continue;
            }
            const bool inside = loop.at > outer.at && loop.at < outer.end;
            if (!inside) {
                continue;
            }
            ++depth;
            if (loop.end > outer.end) {
                error("LOOP body ends past its outer loop's end");
            }
            if (outer.index == loop.index) {
                error("LOOP inside a loop on the same index register");
            }
        }
        if (depth > 1) {
            error("LOOP nested more than one level deep");
        }
    }
}

void Assembler::check_skips() {
    for (const SkipRecord &skip : skips_) {
        line_              = skip.line;
        const size_t first = skip.at + 1;
        const size_t last  = skip.at + skip.count; // inclusive
        for (const LoopRecord &loop : loops_) {
            const bool skips_loop_word = loop.at >= first && loop.at <= last;
            const size_t body_first    = loop.at + 1;
            const size_t body_last     = loop.end - 1;
            const bool overlaps  = first <= body_last && last >= body_first;
            const bool contained = first >= body_first && last <= body_last;
            if (skips_loop_word || (overlaps && !contained)) {
                error("SKIP range crosses a loop boundary");
                break;
            }
        }
    }
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
