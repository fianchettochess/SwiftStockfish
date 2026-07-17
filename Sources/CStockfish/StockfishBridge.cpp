#include "StockfishConfig.h"
#include "StockfishBridge.h"
#include "StockfishIO.h"

// NOTE (SwiftStockfish): the original Fianchetto bridge used "src/<header>"
// paths because the bridge lived one directory above the engine's `src/`
// tree. In this package the engine source lives in `stockfish/` and the
// CStockfish target adds a `.headerSearchPath("stockfish")`, so these are
// bare includes — matching how the engine's own translation units include
// each other.
#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

#include <string>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <iostream>
#include <streambuf>

#if defined(__APPLE__)
    // Apple keeps the existing pthread engine thread + QoS pinning (load-bearing
    // for the recorded Microhang fix). Everywhere else uses std::thread.
    #include <pthread.h>
#else
    #include <thread>
    #include <system_error>  // std::system_error from a failed std::thread construction
#endif

// NOTE: this bridge swaps the process-global `std::cin` / `std::cout`
// rdbufs in the engine thread so Stockfish's UCI loop talks to our
// in-memory queue / output callback instead of the host's stdio. **Only
// one Stockfish engine instance may be live in a process at a time** — a
// second engine's rdbuf swap clobbers the first's, routing the first
// engine's output to the second's callback and leaving the first one's
// caller waiting forever for output that arrived on someone else's stream.
// Worse: the streambufs are STACK LOCALS of `runEngine`, so when the
// clobbered engine's loop exits, the survivor keeps reading a DANGLING
// stack-allocated streambuf through `std::cin` — the 2026-07-01 crash
// reports caught exactly that (getline/memchr walking a dead thread's
// stack into a guard page under Swift Testing's default parallelism,
// and on the stop() → start() restart overlap).
//
// ENFORCED (2026-07-01): `sf_create` now blocks on a process-wide
// lifecycle gate until the previous engine is FULLY destroyed (loop
// joined, rdbufs restored). Overlapping instances serialize instead of
// corrupting each other: parallel engine tests queue up, a restart's
// create waits out the old engine's teardown, and concurrent probes on
// Android line up behind one another. A leaked engine (create with no
// destroy) makes the next create wait forever — a visible hang instead
// of a heisencrash, and a bug in the caller by contract.
//
// PORTABILITY: the former POSIX-pipe I/O (a `pipe()` pair + a reader thread
// doing `read`/`write` on fds) has been replaced with an in-memory
// `CommandQueue` for input and a direct callback for output (see
// StockfishIO.h). The `std::cin/std::cout.rdbuf(...)` swap is unchanged — only
// the two streambufs' backing store changed from fds to the queue/callback.
// This removed the only OS-specific I/O the bridge owned and deleted the reader
// thread entirely (output is now synchronous from the engine thread's `cout`).

using namespace Stockfish;

static bool sfInitialized = false;

// Process-wide exclusive-instance gate (see the NOTE above): held from
// sf_create until the END of sf_destroy. A condvar (not a bare mutex)
// because acquire and release happen on different threads.
static std::mutex gLifecycleMutex;
static std::condition_variable gLifecycleCV;
static bool gEngineLive = false;

struct SFEngineImpl;

// Reads from the in-memory CommandQueue, used as std::cin's streambuf on the
// engine thread. `underflow` block-pops the next command; on shutdown the
// queue returns EOF and the UCI loop exits.
class QueueInputBuf : public std::streambuf {
    SwiftStockfishIO::CommandQueue *queue;
    std::string current;  // backing store for the current command (incl. '\n')
public:
    QueueInputBuf(SwiftStockfishIO::CommandQueue *q) : queue(q) {
        setg(nullptr, nullptr, nullptr);
    }
protected:
    int_type underflow() override {
        if (gptr() < egptr()) return traits_type::to_int_type(*gptr());
        std::string cmd;
        if (!queue->pop(cmd)) return traits_type::eof();  // shutdown -> EOF
        current = std::move(cmd);
        current += '\n';  // the UCI loop reads line-by-line via std::getline
        char *base = current.data();
        setg(base, base, base + current.size());
        return traits_type::to_int_type(*gptr());
    }
};

// Buffers engine output and delivers it to the host callback, used as
// std::cout's streambuf on the engine thread. `overflow`/`xsputn` append to a
// line buffer; on each '\n' the completed line is handed to `impl->callback`
// directly — there is no reader thread and no pipe.
class CallbackOutputBuf : public std::streambuf {
    SFEngineImpl *impl;
    std::string lineBuffer;
    void flushLine();
public:
    CallbackOutputBuf(SFEngineImpl *i) : impl(i) {}
protected:
    int_type overflow(int_type ch) override {
        if (ch != traits_type::eof()) {
            char c = static_cast<char>(ch);
            lineBuffer.push_back(c);
            if (c == '\n') flushLine();
        }
        return ch;
    }
    std::streamsize xsputn(const char *s, std::streamsize n) override {
        for (std::streamsize i = 0; i < n; ++i) {
            char c = s[i];
            lineBuffer.push_back(c);
            if (c == '\n') flushLine();
        }
        return n;
    }
    int sync() override { return 0; }
};

struct SFEngineImpl {
    SwiftStockfishIO::CommandQueue inputQueue;
#if defined(__APPLE__)
    pthread_t engineThread = 0;
#else
    std::thread engineThread;
#endif
    SFOutputCallback callback = nullptr;
    const void *context = nullptr;
    bool running = false;
    std::mutex writeMutex;
    std::string argv0;
};

// Deliver one complete output line (the trailing '\n' is dropped here, matching
// the old reader thread, which split on '\n' and stripped a trailing '\r').
void CallbackOutputBuf::flushLine() {
    // lineBuffer ends in '\n'; drop it, plus a trailing '\r' if present.
    if (!lineBuffer.empty() && lineBuffer.back() == '\n') lineBuffer.pop_back();
    if (!lineBuffer.empty() && lineBuffer.back() == '\r') lineBuffer.pop_back();
    if (!lineBuffer.empty() && impl->callback)
        impl->callback(lineBuffer.c_str(), impl->context);
    lineBuffer.clear();
}

namespace {

// The engine thread body, shared by both the Apple (pthread) and non-Apple
// (std::thread) arms. Redirects cin/cout at the C++ stream level — does NOT
// touch fd 0/1, so the test runner and Swift print() keep working normally —
// then runs Stockfish's UCI loop until the input queue signals EOF.
void runEngine(SFEngineImpl *impl) {
    QueueInputBuf inputBuf(&impl->inputQueue);
    CallbackOutputBuf outputBuf(impl);

    auto oldCin = std::cin.rdbuf(&inputBuf);
    auto oldCout = std::cout.rdbuf(&outputBuf);

    char *argv0Ptr = impl->argv0.data();
    char *argv[] = {argv0Ptr, nullptr};
    auto uci = std::make_unique<UCIEngine>(1, argv);
    Tune::init(uci->engine_options());
    uci->loop();

    std::cin.rdbuf(oldCin);
    std::cout.rdbuf(oldCout);
}

}  // namespace

extern "C" {

SFEngineRef sf_create(const char *nnueDir) {
    // Wait for the previous engine (if any) to be fully torn down before
    // touching the process-global cin/cout state. Blocks the calling
    // thread — callers already invoke sf_create off the main thread.
    {
        std::unique_lock<std::mutex> lock(gLifecycleMutex);
        gLifecycleCV.wait(lock, [] { return !gEngineLive; });
        gEngineLive = true;
    }

    auto impl = new SFEngineImpl();

    if (!sfInitialized) {
        Bitboards::init();
        Position::init();
        sfInitialized = true;
    }

    // Build argv[0] so Stockfish's binaryDirectory points to the NNUE files
    std::string argv0;
    if (nnueDir && nnueDir[0]) {
        argv0 = std::string(nnueDir) + "/stockfish";
    } else {
        argv0 = "stockfish";
    }
    impl->argv0 = argv0;

    impl->running = true;

#if defined(__APPLE__)
    // Pin the engine thread (and any workers Stockfish spawns from it) to
    // QOS_CLASS_UTILITY. Without this they inherit the QoS of whichever Swift
    // queue called `sf_create` — historically `.userInitiated` — which puts
    // the search workers at the same priority class as the SwiftUI main
    // thread. On the 2026-05-29 Instruments trace that produced 9 Microhangs
    // of 300-380 ms each: while Stockfish workers saturated the P cores at
    // userInitiated, every main-thread SwiftUI transaction commit stretched
    // from ~5 ms to ~40 ms because the scheduler had no headroom. Lowering to
    // utility keeps the analyses fast when the UI is idle (the scheduler still
    // gives them all available CPU) but reserves headroom for the main thread
    // the moment it has work to do.
    //
    // Engine thread with 4MB stack for iOS compatibility.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0);

    int threadCreateResult = pthread_create(&impl->engineThread, &attr, [](void *arg) -> void * {
        runEngine(static_cast<SFEngineImpl *>(arg));
        return nullptr;
    }, impl);

    pthread_attr_destroy(&attr);

    if (threadCreateResult != 0) {
        // EAGAIN (thread exhaustion / memory pressure) etc.: no engine thread
        // exists, so returning this ref would hand back a live-looking engine
        // that can never produce output — callers would burn their full
        // ready-timeout before noticing. Fail the create instead: NULL is the
        // bridge's create-failure convention (StockfishEngine.init? surfaces
        // it as nil). MUST release the lifecycle gate here, exactly as
        // sf_destroy does — a failed create that kept gEngineLive set would
        // leak the one-live-engine slot and hang every later sf_create.
        delete impl;
        {
            std::lock_guard<std::mutex> lock(gLifecycleMutex);
            gEngineLive = false;
        }
        gLifecycleCV.notify_one();
        return nullptr;
    }
#else
    // Non-Apple: a plain std::thread engine thread. Stockfish's own internals
    // already use std::thread off-Apple (thread_win32_osx.h), and there is no
    // portable QoS equivalent, so we simply spawn the loop. Output is
    // synchronous via the callback streambuf — there is no reader thread on any
    // platform.
    //
    // std::thread's constructor throws std::system_error on resource
    // exhaustion; uncaught it would propagate out of this extern "C" function
    // and std::terminate the process. Convert it to the bridge's NULL-return
    // failure convention instead, releasing the lifecycle gate exactly as
    // sf_destroy does so a failed create cannot leak the one-live-engine slot.
    try {
        impl->engineThread = std::thread([impl]() { runEngine(impl); });
    } catch (const std::system_error &) {
        delete impl;
        {
            std::lock_guard<std::mutex> lock(gLifecycleMutex);
            gEngineLive = false;
        }
        gLifecycleCV.notify_one();
        return nullptr;
    }
#endif

    return (SFEngineRef)impl;
}

void sf_destroy(SFEngineRef ref) {
    if (!ref) return;
    auto impl = (SFEngineImpl *)ref;

    impl->running = false;

    {
        // Push the terminating "quit" and signal shutdown. The condvar wakes
        // the engine thread's `underflow`: it pops "quit" (the UCI loop exits)
        // and, once the queue drains, returns EOF — so the loop also exits even
        // if the engine never consumes the command.
        std::lock_guard<std::mutex> lock(impl->writeMutex);
        impl->inputQueue.push("quit");
        impl->inputQueue.shutdown();
    }

#if defined(__APPLE__)
    if (impl->engineThread)
        pthread_join(impl->engineThread, nullptr);
#else
    if (impl->engineThread.joinable())
        impl->engineThread.join();
#endif

    delete impl;

    // Loop joined, rdbufs restored, impl freed — release the lifecycle
    // gate so a waiting sf_create can proceed against clean global state.
    {
        std::lock_guard<std::mutex> lock(gLifecycleMutex);
        gEngineLive = false;
    }
    gLifecycleCV.notify_one();
}

void sf_set_output_callback(SFEngineRef ref, SFOutputCallback callback, const void *context) {
    if (!ref) return;
    auto impl = (SFEngineImpl *)ref;
    impl->callback = callback;
    impl->context = context;
}

void sf_send_command(SFEngineRef ref, const char *command) {
    // Guard the raw C ABI: a NULL `command` would make `std::string(command)`
    // undefined behaviour (a crash); a NULL `ref` is a no-op. The Swift
    // StockfishEngine wrapper never trips these, but a direct CStockfish consumer
    // can — see the exactly-once / no-concurrent-use contract in StockfishBridge.h.
    if (!ref || !command) return;
    auto impl = (SFEngineImpl *)ref;
    std::lock_guard<std::mutex> lock(impl->writeMutex);
    impl->inputQueue.push(std::string(command));
}

bool sf_wait_idle(int timeoutMs) {
    std::unique_lock<std::mutex> lock(gLifecycleMutex);
    return gLifecycleCV.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                                 [] { return !gEngineLive; });
}

}
