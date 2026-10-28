// Replay physical timing only; controller queues and arbitration are not replayed.
#include "channel_state.h"

#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>

using dramsim3::Address;
using dramsim3::Command;
using dramsim3::CommandType;

namespace {
const std::map<std::string, CommandType> types = {
    {"read", CommandType::READ}, {"write", CommandType::WRITE},
    {"activate", CommandType::ACTIVATE}, {"precharge", CommandType::PRECHARGE},
    {"refresh", CommandType::REFRESH}};

struct Record {
  uint64_t clk;
  Command cmd;
  std::string kind;
};

Address ReadAddress(std::istream& input) {
  int fields[6];
  for (auto& field : fields) {
    std::string word;
    if (!(input >> word)) throw std::runtime_error("Incomplete address");
    size_t end;
    field = std::stoi(word, &end, 0);
    if (end != word.size()) throw std::runtime_error("Invalid address field");
  }
  return Address(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]);
}

void CheckAddress(const Address& a, const dramsim3::Config& cfg, bool rank_only) {
  // Refresh-generated commands use -1 for fields not consumed by ChannelState.
  if ((a.channel != 0 && a.channel != -1) || a.rank < 0 || a.rank >= cfg.ranks ||
      (!rank_only && (a.bankgroup < 0 || a.bankgroup >= cfg.bankgroups ||
                     a.bank < 0 || a.bank >= cfg.banks_per_group))) {
    throw std::runtime_error("Address outside single-channel configuration");
  }
}

// Keep the origin of each bank's limiting timestamp, using native Timing tables.
struct Limit {
  uint64_t until = 0;
  unsigned origins = 0;
};

std::string Origins(unsigned mask) {
  std::string result;
  for (const auto& [name, type] : types) {
    if (mask & (1u << static_cast<int>(type))) {
      if (!result.empty()) result += '+';
      result += name;
    }
  }
  return result.empty() ? "none" : result;
}
}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 5) throw std::runtime_error("Usage: probe CONFIG COMMANDS QUERIES OUTDIR");
    dramsim3::Config cfg(argv[1], argv[4]);
    if (cfg.channels != 1) throw std::runtime_error("Only one channel is supported");
    dramsim3::Timing timing(cfg);
    dramsim3::ChannelState state(cfg, timing);
    constexpr int ntypes = static_cast<int>(CommandType::SIZE);
    std::vector<std::vector<Limit>> limits(cfg.ranks * cfg.bankgroups * cfg.banks_per_group,
                                         std::vector<Limit>(ntypes));
    auto bank_index = [&](int rank, int bg, int bank) {
      return (rank * cfg.bankgroups + bg) * cfg.banks_per_group + bank;
    };
    std::ifstream commands_file(argv[2]), queries_file(argv[3]);
    if (!commands_file || !queries_file) throw std::runtime_error("Cannot open trace/query file");
    std::vector<Record> commands;
    std::string line;
    while (std::getline(commands_file, line)) {
      std::istringstream input(line);
      uint64_t tick, clk;
      std::string kind, extra;
      if (!(input >> tick >> clk >> kind) || tick != clk + 1 ||
          (!commands.empty() && clk <= commands.back().clk)) {
        throw std::runtime_error("Invalid command clock/order");
      }
      auto address = ReadAddress(input);
      if (input >> extra) throw std::runtime_error("Extra command fields");
      auto type = types.at(kind);
      CheckAddress(address, cfg, type == CommandType::REFRESH);
      commands.push_back({clk, Command(type, address, 0), kind});
    }
    if (commands.empty()) throw std::runtime_error("Empty command trace");

    auto apply = [&](const Record& record) {
      Command check = record.cmd;
      // BankState accepts transaction/refresh targets and returns ACT/PRE prerequisites.
      if (check.cmd_type == CommandType::ACTIVATE || check.cmd_type == CommandType::PRECHARGE) {
        if (check.cmd_type == CommandType::PRECHARGE) check.addr.row = -1;
        check.cmd_type = CommandType::READ;
      }
      auto ready = state.GetReadyCommand(check, record.clk);
      if (ready.cmd_type != record.cmd.cmd_type) {
        throw std::runtime_error("Native command failed timing validation at clock " +
                                 std::to_string(record.clk) + " (" + record.kind + ")");
      }
      state.UpdateTimingAndStates(record.cmd, record.clk);
      const auto& a = record.cmd.addr;
      int type = static_cast<int>(record.cmd.cmd_type);
      for (int rank = 0; rank < cfg.ranks; ++rank) {
        for (int bg = 0; bg < cfg.bankgroups; ++bg) {
          for (int bank = 0; bank < cfg.banks_per_group; ++bank) {
            const std::vector<std::pair<CommandType, int>>* table;
            if (record.cmd.IsRankCMD()) {
              if (rank != a.rank) continue;
              table = &timing.same_rank[type];
            } else if (rank != a.rank) {
              table = &timing.other_ranks[type];
            } else if (bg != a.bankgroup) {
              table = &timing.other_bankgroups_same_rank[type];
            } else if (bank != a.bank) {
              table = &timing.other_banks_same_bankgroup[type];
            } else {
              table = &timing.same_bank[type];
            }
            for (auto [target, delay] : *table) {
              auto& limit = limits[bank_index(rank, bg, bank)][static_cast<int>(target)];
              // Match the native unsigned timestamp addition, including signed delays.
              uint64_t until = record.clk + delay;
              if (until > limit.until) limit = {until, 1u << type};
              else if (until == limit.until) limit.origins |= 1u << type;
            }
          }
        }
      }
    };

    size_t cursor = 0, query_count = 0;
    uint64_t previous_clk = 0;
    std::ostringstream output;
    while (std::getline(queries_file, line)) {
      std::istringstream input(line);
      uint64_t id, clk;
      std::string extra;
      if (!(input >> id >> clk) || (query_count && clk < previous_clk)) {
        throw std::runtime_error("Invalid query clock/order");
      }
      auto a = ReadAddress(input);
      CheckAddress(a, cfg, false);
      if (input >> extra) throw std::runtime_error("Extra query fields");
      previous_clk = clk;
      // Observe before the command issued on this same native clock.
      while (cursor < commands.size() && commands[cursor].clk < clk) apply(commands[cursor++]);
      auto ready = state.GetReadyCommand(Command(CommandType::READ, a, 0), clk);
      int row = state.OpenRow(a.rank, a.bankgroup, a.bank);
      CommandType required = row == -1 ? CommandType::ACTIVATE :
                             row == a.row ? CommandType::READ : CommandType::PRECHARGE;
      const auto& limit = limits[bank_index(a.rank, a.bankgroup, a.bank)][static_cast<int>(required)];
      std::string step = required == CommandType::ACTIVATE ? "activate" :
                         required == CommandType::PRECHARGE ? "precharge" : "read";
      std::string category;
      if (ready.IsValid()) {
        if (ready.cmd_type != required || clk < limit.until) {
          throw std::runtime_error("Timing origin tracker differs from native readiness");
        }
        category = step + "_ready";
      } else if (clk < limit.until) {
        category = step + "_timing";
      } else if (required == CommandType::ACTIVATE && !state.ActivationWindowOk(a.rank, clk)) {
        category = "activate_window";
      } else {
        throw std::runtime_error("Unexplained physical timing block");
      }
      std::string same_clock = cursor < commands.size() && commands[cursor].clk == clk ?
                               commands[cursor].kind : "none";
      output << id << ' ' << clk << ' ' << category << ' '
             << (clk < limit.until ? Origins(limit.origins) : "none") << ' '
             << row << ' ' << limit.until << ' ' << same_clock << '\n';
      ++query_count;
    }
    while (cursor < commands.size()) apply(commands[cursor++]);
    std::cout << output.str();
    std::cerr << "Validated " << commands.size() << " native commands; "
              << query_count << " queries\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
