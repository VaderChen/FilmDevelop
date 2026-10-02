#pragma once
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <exception>
#include <functional>
#include <mutex>
#include <thread>
#include <system_error>
#include <vector>

namespace photocore::film_cpu {
// 各像素的運算與累加順序不變，只平行處理獨立列；最多使用八個執行緒。
class RowWorkers {
    std::mutex submission_, state_;
    std::condition_variable start_, complete_;
    std::vector<std::thread> workers_;
    std::function<void(std::size_t)> work_;
    std::atomic<std::size_t> next_{0};
    std::atomic<bool> failed_{false};
    std::size_t rows_ = 0, generation_ = 0, pending_ = 0;
    bool stop_ = false;
    std::exception_ptr error_;
    inline static thread_local bool executing_ = false;

    void consume() noexcept {
        executing_ = true;
        try {
            while (!failed_.load(std::memory_order_relaxed)) {
                const auto row = next_.fetch_add(1, std::memory_order_relaxed);
                if (row >= rows_) break;
                work_(row);
            }
        } catch (...) {
            std::lock_guard<std::mutex> lock(state_);
            if (!error_) error_ = std::current_exception();
            failed_.store(true, std::memory_order_relaxed);
        }
        executing_ = false;
    }
    void worker() {
        std::size_t seen = 0;
        std::unique_lock<std::mutex> lock(state_);
        for (;;) {
            start_.wait(lock, [&] { return stop_ || generation_ != seen; });
            if (stop_) return;
            seen = generation_;
            lock.unlock();
            consume();
            lock.lock();
            if (--pending_ == 0) complete_.notify_one();
        }
    }
public:
    RowWorkers() {
        const unsigned count = std::min(8U, std::max(1U, std::thread::hardware_concurrency()));
        workers_.reserve(count - 1);
        // 系統無法建立更多執行緒時沿用已建立的數量，呼叫端仍參與計算。
        for (unsigned i = 1; i < count; ++i) {
            try { workers_.emplace_back([this] { worker(); }); }
            catch (const std::system_error &) { break; }
        }
    }
    ~RowWorkers() {
        { std::lock_guard<std::mutex> lock(state_); stop_ = true; }
        start_.notify_all();
        for (auto &worker : workers_) worker.join();
    }
    template<class F> void run(std::size_t rows, std::size_t width, const F &fn) {
        // 巢狀呼叫直接執行，避免工作者等待自己的批次；小圖免去排程成本。
        if (executing_ || rows < 2 || width < (32768 + rows - 1) / rows || workers_.empty()) {
            for (std::size_t y = 0; y < rows; ++y) fn(y);
            return;
        }
        std::lock_guard<std::mutex> submission(submission_);
        {
            std::lock_guard<std::mutex> lock(state_);
            work_ = fn; rows_ = rows; next_ = 0; failed_ = false; error_ = nullptr;
            pending_ = workers_.size(); ++generation_;
        }
        start_.notify_all();
        consume();
        std::unique_lock<std::mutex> lock(state_);
        complete_.wait(lock, [&] { return pending_ == 0; });
        work_ = {};
        if (error_) std::rethrow_exception(error_);
    }
};
inline RowWorkers &shared_row_workers() { static RowWorkers workers; return workers; }
template<class F> void parallel_rows(std::size_t rows, std::size_t width, const F &fn) {
    // 函式模板不可各自建立一個 pool，所有演算共用此非模板入口。
    shared_row_workers().run(rows, width, fn);
}
} // namespace photocore::film_cpu
