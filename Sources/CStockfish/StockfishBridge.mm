#include "StockfishConfig.h"
#include "StockfishBridge.h"

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

#include <pthread.h>
#include <unistd.h>
#include <string>
#include <mutex>
#include <cstring>
#include <iostream>
#include <streambuf>

// NOTE: this bridge swaps the process-global `std::cin` / `std::cout`
// rdbufs in the engine thread so Stockfish's UCI loop talks to our
// pipes instead of the host's stdio. **Only one Stockfish engine
// instance may be live in a process at a time** — a second engine's
// rdbuf swap clobbers the first's, routing the first engine's
// output to the second's pipe and leaving the first one's caller
// waiting forever for output that arrived on someone else's stream.
// In the app this is enforced naturally (one `EngineManager`). In
// tests, `ContentView.task` is gated on `XCTestConfigurationFilePath`
// so the app-side warm-up doesn't fire while a test owns the
// engine.

using namespace Stockfish;

static bool sfInitialized = false;

// Reads from a pipe fd, used as std::cin's streambuf on the engine thread
class PipeInputBuf : public std::streambuf {
    int fd;
    char buf[1024];
public:
    PipeInputBuf(int fd) : fd(fd) { setg(buf, buf, buf); }
protected:
    int_type underflow() override {
        if (gptr() < egptr()) return traits_type::to_int_type(*gptr());
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) return traits_type::eof();
        setg(buf, buf, buf + n);
        return traits_type::to_int_type(*gptr());
    }
};

// Writes to a pipe fd, used as std::cout's streambuf on the engine thread
class PipeOutputBuf : public std::streambuf {
    int fd;
public:
    PipeOutputBuf(int fd) : fd(fd) {}
protected:
    int_type overflow(int_type ch) override {
        if (ch != traits_type::eof()) {
            char c = static_cast<char>(ch);
            if (write(fd, &c, 1) != 1) return traits_type::eof();
        }
        return ch;
    }
    std::streamsize xsputn(const char* s, std::streamsize n) override {
        ssize_t written = write(fd, s, static_cast<size_t>(n));
        return written > 0 ? written : 0;
    }
    int sync() override { return 0; }
};

struct SFEngineImpl {
    int stdinPipe[2] = {-1, -1};
    int stdoutPipe[2] = {-1, -1};
    pthread_t engineThread = 0;
    pthread_t readerThread = 0;
    SFOutputCallback callback = nullptr;
    const void *context = nullptr;
    bool running = false;
    std::mutex writeMutex;
    std::string argv0;
};

extern "C" {

SFEngineRef sf_create(const char *nnueDir) {
    auto impl = new SFEngineImpl();

    if (!sfInitialized) {
        Bitboards::init();
        Position::init();
        sfInitialized = true;
    }

    if (pipe(impl->stdinPipe) != 0 || pipe(impl->stdoutPipe) != 0) {
        delete impl;
        return nullptr;
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

    // Pin both threads (and any workers Stockfish spawns from the
    // engine thread) to QOS_CLASS_UTILITY. Without this they inherit
    // the QoS of whichever Swift queue called `sf_create` —
    // historically `.userInitiated` — which puts the search workers
    // at the same priority class as the SwiftUI main thread. On the
    // 2026-05-29 Instruments trace that produced 9 Microhangs of
    // 300-380 ms each: while Stockfish workers saturated the P
    // cores at userInitiated, every main-thread SwiftUI transaction
    // commit stretched from ~5 ms to ~40 ms because the scheduler
    // had no headroom. Lowering to utility keeps the analyses fast
    // when the UI is idle (the scheduler still gives them all
    // available CPU) but reserves headroom for the main thread the
    // moment it has work to do.
    pthread_attr_t readerAttr;
    pthread_attr_init(&readerAttr);
    pthread_attr_set_qos_class_np(&readerAttr, QOS_CLASS_UTILITY, 0);

    // Reader thread: captures engine output from the pipe and delivers via callback
    pthread_create(&impl->readerThread, &readerAttr, [](void *arg) -> void * {
        auto impl = static_cast<SFEngineImpl *>(arg);
        char buf[4096];
        std::string lineBuffer;

        while (impl->running) {
            ssize_t n = read(impl->stdoutPipe[0], buf, sizeof(buf) - 1);
            if (n <= 0) break;
            buf[n] = '\0';
            lineBuffer += buf;

            size_t pos;
            while ((pos = lineBuffer.find('\n')) != std::string::npos) {
                std::string line = lineBuffer.substr(0, pos);
                lineBuffer.erase(0, pos + 1);
                if (!line.empty() && line.back() == '\r')
                    line.pop_back();
                if (!line.empty() && impl->callback)
                    impl->callback(line.c_str(), impl->context);
            }
        }
        return nullptr;
    }, impl);

    pthread_attr_destroy(&readerAttr);

    // Engine thread with 4MB stack for iOS compatibility.
    // QoS = utility for the same reason as the reader (and so the
    // worker threads Stockfish spawns from this thread inherit
    // utility too — see the comment above).
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0);

    pthread_create(&impl->engineThread, &attr, [](void *arg) -> void * {
        auto impl = static_cast<SFEngineImpl *>(arg);

        // Redirect cin/cout at the C++ stream level — does NOT touch fd 0/1,
        // so the test runner and Swift print() keep working normally.
        PipeInputBuf inputBuf(impl->stdinPipe[0]);
        PipeOutputBuf outputBuf(impl->stdoutPipe[1]);

        auto oldCin = std::cin.rdbuf(&inputBuf);
        auto oldCout = std::cout.rdbuf(&outputBuf);

        char *argv0Ptr = impl->argv0.data();
        char *argv[] = {argv0Ptr, nullptr};
        auto uci = std::make_unique<UCIEngine>(1, argv);
        Tune::init(uci->engine_options());
        uci->loop();

        std::cin.rdbuf(oldCin);
        std::cout.rdbuf(oldCout);

        close(impl->stdoutPipe[1]);
        impl->stdoutPipe[1] = -1;

        return nullptr;
    }, impl);

    pthread_attr_destroy(&attr);

    return (SFEngineRef)impl;
}

void sf_destroy(SFEngineRef ref) {
    if (!ref) return;
    auto impl = (SFEngineImpl *)ref;

    impl->running = false;

    {
        std::lock_guard<std::mutex> lock(impl->writeMutex);
        const char *quit = "quit\n";
        if (impl->stdinPipe[1] >= 0)
            write(impl->stdinPipe[1], quit, strlen(quit));
    }

    if (impl->engineThread)
        pthread_join(impl->engineThread, nullptr);

    if (impl->stdinPipe[0] >= 0) close(impl->stdinPipe[0]);
    if (impl->stdinPipe[1] >= 0) close(impl->stdinPipe[1]);

    if (impl->readerThread)
        pthread_join(impl->readerThread, nullptr);

    if (impl->stdoutPipe[0] >= 0) close(impl->stdoutPipe[0]);

    delete impl;
}

void sf_set_output_callback(SFEngineRef ref, SFOutputCallback callback, const void *context) {
    if (!ref) return;
    auto impl = (SFEngineImpl *)ref;
    impl->callback = callback;
    impl->context = context;
}

void sf_send_command(SFEngineRef ref, const char *command) {
    if (!ref) return;
    auto impl = (SFEngineImpl *)ref;
    std::lock_guard<std::mutex> lock(impl->writeMutex);
    std::string cmd(command);
    cmd += "\n";
    write(impl->stdinPipe[1], cmd.c_str(), cmd.size());
}

}
