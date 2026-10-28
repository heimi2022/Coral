// C ABI for cocotb/ctypes. DRAMsim3 owns timing; Python owns AXI and data.
#include <cstdint>
#include <deque>
#include <dlfcn.h>
#include <map>
#include <memory>
#include <utility>

#ifdef CORAL_DRAM_COMMAND_TRACE
#include <cstdlib>
#include <fstream>
#include <ostream>

// Observe the shipped library through its exported function and formatter.
// Command/ChannelState remain opaque; no private object layout is assumed.
namespace dramsim3 {
class Command;
std::ostream& operator<<(std::ostream&, const Command&);
}

namespace {
thread_local std::ofstream* command_trace = nullptr;
thread_local uint64_t* command_count = nullptr;
thread_local uint64_t command_tick = 0;
}

extern "C" void coral_observe_command(void*, const dramsim3::Command&, uint64_t)
    asm("_ZN8dramsim312ChannelState21UpdateTimingAndStatesERKNS_7CommandEm");

extern "C" void coral_observe_command(void* state, const dramsim3::Command& cmd,
                                     uint64_t clk) {
  using Update = void (*)(void*, const dramsim3::Command&, uint64_t);
  static auto original = reinterpret_cast<Update>(dlsym(
      RTLD_NEXT, "_ZN8dramsim312ChannelState21UpdateTimingAndStatesERKNS_7CommandEm"));
  if (!original) std::abort();
  if (command_trace) {
    *command_trace << command_tick << ' ' << clk << ' ' << cmd << '\n';
    ++*command_count;
  }
  original(state, cmd, clk);
}
#endif

#include "dramsim3.h"

namespace {
struct Backend {
  using Key = std::pair<uint64_t, bool>;
  std::map<Key, std::deque<uint64_t>> pending;
  std::deque<std::pair<uint64_t, uint64_t>> completed;
  uint64_t ticks = 0;
#ifdef CORAL_DRAM_COMMAND_TRACE
  std::ofstream commands;
  uint64_t commands_seen = 0;
#endif
  bool callback_error = false;
  std::unique_ptr<dramsim3::MemorySystem> memory;

  Backend(const char* config, const char* output) {
#ifdef CORAL_DRAM_COMMAND_TRACE
    commands.open(std::string(output) + "ddr_commands.trace");
    if (!commands) std::abort();
#endif
    memory.reset(dramsim3::GetMemorySystem(
        config, output, [this](uint64_t addr) { Complete(addr, false); },
        [this](uint64_t addr) { Complete(addr, true); }));
  }

  void Complete(uint64_t addr, bool write) {
    auto it = pending.find({addr, write});
    if (it == pending.end() || it->second.empty()) {
      callback_error = true;
      return;
    }
    completed.emplace_back(it->second.front(), ticks);
    it->second.pop_front();
    if (it->second.empty()) pending.erase(it);
  }
};
}  // namespace

extern "C" {
const char* coral_dram_backend_library() {
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(&dramsim3::GetMemorySystem), &info))
    return nullptr;
  return info.dli_fname;
}

void* coral_dram_create(const char* config, const char* output) {
  return new Backend(config, output);
}

double coral_dram_tck(void* handle) {
  return static_cast<Backend*>(handle)->memory->GetTCK();
}

int coral_dram_transaction_bytes(void* handle) {
  auto& memory = static_cast<Backend*>(handle)->memory;
  return memory->GetBusBits() / 8 * memory->GetBurstLength();
}

int coral_dram_submit(void* handle, uint64_t address, int write, uint64_t tag) {
  auto* backend = static_cast<Backend*>(handle);
  if (!backend->memory->WillAcceptTransaction(address, write != 0)) return 0;
  auto& queue = backend->pending[{address, write != 0}];
  queue.push_back(tag);
  if (!backend->memory->AddTransaction(address, write != 0)) {
    queue.pop_back();
    if (queue.empty()) backend->pending.erase({address, write != 0});
    return 0;
  }
  return 1;
}

void coral_dram_tick(void* handle) {
  auto* backend = static_cast<Backend*>(handle);
  ++backend->ticks;
#ifdef CORAL_DRAM_COMMAND_TRACE
  command_trace = &backend->commands;
  command_count = &backend->commands_seen;
  command_tick = backend->ticks;
#endif
  backend->memory->ClockTick();
#ifdef CORAL_DRAM_COMMAND_TRACE
  command_trace = nullptr;
  command_count = nullptr;
#endif
}

uint64_t coral_dram_command_count(void* handle) {
#ifdef CORAL_DRAM_COMMAND_TRACE
  return static_cast<Backend*>(handle)->commands_seen;
#else
  return 0;
#endif
}

int coral_dram_poll_timed(void* handle, uint64_t* tag, uint64_t* tick) {
  auto* backend = static_cast<Backend*>(handle);
  if (backend->callback_error) return -1;
  if (backend->completed.empty()) return 0;
  *tag = backend->completed.front().first;
  *tick = backend->completed.front().second;
  backend->completed.pop_front();
  return 1;
}

int coral_dram_poll(void* handle, uint64_t* tag) {
  uint64_t tick;
  return coral_dram_poll_timed(handle, tag, &tick);
}

void coral_dram_stats(void* handle) {
#ifdef CORAL_DRAM_COMMAND_TRACE
  static_cast<Backend*>(handle)->commands.flush();
#endif
  static_cast<Backend*>(handle)->memory->PrintStats();
}

void coral_dram_destroy(void* handle) { delete static_cast<Backend*>(handle); }
}
