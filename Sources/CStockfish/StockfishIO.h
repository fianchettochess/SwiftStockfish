#ifndef STOCKFISH_IO_H
#define STOCKFISH_IO_H

// Portable in-memory command queue for the SwiftStockfish bridge.
//
// This replaces the bridge's former POSIX-pipe I/O (a `pipe()` pair plus a
// reader thread doing `read`/`write` on fds). Input commands are pushed onto a
// thread-safe queue and the engine thread's `std::cin` streambuf block-pops
// them; engine output goes straight to the host callback (no pipe, no reader
// thread). Nothing here is platform-specific — `std::queue`, `std::mutex` and
// `std::condition_variable` are all standard C++11 — so the bridge compiles
// identically on Apple, Linux, Windows and WASM.

#include <condition_variable>
#include <mutex>
#include <queue>
#include <string>

namespace SwiftStockfishIO {

// Thread-safe single-producer/single-consumer string queue with a shutdown
// flag. The producer is `sf_send_command` (and `sf_destroy`, which pushes the
// terminating "quit"); the consumer is the engine thread via the input
// streambuf's `underflow`.
class CommandQueue {
public:
    // Push a command onto the queue and wake a blocked consumer.
    void push(const std::string &cmd) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push(cmd);
        }
        cv_.notify_one();
    }

    // Block until a command is available or shutdown is requested. Returns
    // false (with `out` untouched) once shutdown has been signalled AND the
    // queue has been drained — the consumer treats that as EOF. Otherwise pops
    // the next command into `out` and returns true.
    bool pop(std::string &out) {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return shutdown_ || !queue_.empty(); });
        if (!queue_.empty()) {
            out = std::move(queue_.front());
            queue_.pop();
            return true;
        }
        // shutdown_ is set and the queue is empty -> signal EOF.
        return false;
    }

    // Request shutdown and wake any blocked consumer so it can observe EOF.
    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            shutdown_ = true;
        }
        cv_.notify_all();
    }

private:
    std::queue<std::string> queue_;
    std::mutex mutex_;
    std::condition_variable cv_;
    bool shutdown_ = false;
};

}  // namespace SwiftStockfishIO

#endif
