/*
 * Copyright (c) 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include "../stdexec/execution.hpp"
#include <type_traits>

#include "detail/config.cuh"
#include "stream/sync_wait.cuh"
#include "stream/bulk.cuh"
#include "stream/let_xxx.cuh"
#include "stream/schedule_from.cuh"
#include "stream/start_detached.cuh"
#include "stream/submit.cuh"
#include "stream/split.cuh"
#include "stream/then.cuh"
#include "stream/transfer.cuh"
#include "stream/upon_error.cuh"
#include "stream/upon_stopped.cuh"
#include "stream/when_all.cuh"
#include "stream/reduce.cuh"
#include "stream/ensure_started.cuh"

#include "stream/common.cuh"
#include "detail/queue.cuh"
#include "detail/throw_on_cuda_error.cuh"

namespace nvexec {
  namespace STDEXEC_STREAM_DETAIL_NS {
    template <stdexec::sender Sender, std::integral Shape, class Fun>
      using bulk_sender_th = bulk_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>, Shape, stdexec::__x<std::remove_cvref_t<Fun>>>;

    template <stdexec::sender Sender>
      using split_sender_th = split_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>>;

    template <stdexec::sender Sender, class Fun>
      using then_sender_th = then_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>, stdexec::__x<std::remove_cvref_t<Fun>>>;

    template <class Scheduler, stdexec::sender... Senders>
      using when_all_sender_th = when_all_sender_t<false, Scheduler, stdexec::__x<std::decay_t<Senders>>...>;

    template <class Scheduler, stdexec::sender... Senders>
      using transfer_when_all_sender_th = when_all_sender_t<true, Scheduler, stdexec::__x<std::decay_t<Senders>>...>;

    template <stdexec::sender Sender, class Fun>
      using upon_error_sender_th = upon_error_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>, stdexec::__x<std::remove_cvref_t<Fun>>>;

    template <stdexec::sender Sender, class Fun>
      using upon_stopped_sender_th = upon_stopped_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>, stdexec::__x<std::remove_cvref_t<Fun>>>;

    template <class Let, stdexec::sender Sender, class Fun>
      using let_xxx_th = let_sender_t<stdexec::__x<std::remove_cvref_t<Sender>>, stdexec::__x<std::remove_cvref_t<Fun>>, Let>;

    template <stdexec::sender Sender>
      using transfer_sender_th = transfer_sender_t<stdexec::__x<Sender>>;

    template <stdexec::sender Sender>
      using ensure_started_th = ensure_started_sender_t<stdexec::__x<Sender>>;

    struct stream_scheduler {
      friend stream_context;

      template <stdexec::sender Sender>
        using schedule_from_sender_th = schedule_from_sender_t<stream_scheduler, stdexec::__x<std::remove_cvref_t<Sender>>>;

      template <class RId>
        struct operation_state_t : stream_op_state_base {
          using R = stdexec::__t<RId>;

          R rec_;
          cudaStream_t stream_{0};
          cudaError_t status_{cudaSuccess};

          operation_state_t(R&& rec) : rec_((R&&)rec) {
            status_ = STDEXEC_DBG_ERR(cudaStreamCreate(&stream_));
          }

          ~operation_state_t() {
            STDEXEC_DBG_ERR(cudaStreamDestroy(stream_));
          }

          cudaStream_t get_stream() {
            return stream_;
          }

          friend void tag_invoke(stdexec::start_t, operation_state_t& op) noexcept {
            if constexpr (stream_receiver<R>) {
              if (op.status_ == cudaSuccess) {
                stdexec::set_value((R&&)op.rec_);
              } else {
                stdexec::set_error((R&&)op.rec_, std::move(op.status_));
              }
            } else {
              if (op.status_ == cudaSuccess) {
                continuation_kernel
                  <std::decay_t<R>, stdexec::set_value_t>
                    <<<1, 1, 0, op.stream_>>>(op.rec_, stdexec::set_value);
              } else {
                continuation_kernel
                  <std::decay_t<R>, stdexec::set_error_t, cudaError_t>
                    <<<1, 1, 0, op.stream_>>>(op.rec_, stdexec::set_error, op.status_);
              }
            }
          }
        };

      struct sender_t : stream_sender_base {
        using completion_signatures =
          stdexec::completion_signatures<
            stdexec::set_value_t(),
            stdexec::set_error_t(cudaError_t)>;

        template <class R>
          friend auto tag_invoke(stdexec::connect_t, sender_t, R&& rec)
            noexcept(std::is_nothrow_constructible_v<std::remove_cvref_t<R>, R>)
            -> operation_state_t<stdexec::__x<std::remove_cvref_t<R>>> {
            return operation_state_t<stdexec::__x<std::remove_cvref_t<R>>>((R&&) rec);
          }

        stream_scheduler make_scheduler() const {
          return stream_scheduler{hub_};
        }

        template <class CPO>
        friend stream_scheduler
        tag_invoke(stdexec::get_completion_scheduler_t<CPO>, sender_t self) noexcept {
          return self.make_scheduler();
        }

        sender_t(queue::task_hub_t* hub) noexcept
          : hub_(hub) {}

        queue::task_hub_t * hub_;
      };

      template <stdexec::sender S>
        friend schedule_from_sender_th<S>
        tag_invoke(stdexec::schedule_from_t, const stream_scheduler& sch, S&& sndr) noexcept {
          return schedule_from_sender_th<S>(sch.hub_, (S&&) sndr);
        }

      template <stdexec::sender S, std::integral Shape, class Fn>
        friend bulk_sender_th<S, Shape, Fn>
        tag_invoke(stdexec::bulk_t, const stream_scheduler& sch, S&& sndr, Shape shape, Fn fun) noexcept {
          return bulk_sender_th<S, Shape, Fn>{{}, (S&&) sndr, shape, (Fn&&)fun};
        }

      template <stdexec::sender S, class Fn>
        friend then_sender_th<S, Fn>
        tag_invoke(stdexec::then_t, const stream_scheduler& sch, S&& sndr, Fn fun) noexcept {
          return then_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
        }

      template <stdexec::sender S>
        friend ensure_started_th<S>
        tag_invoke(stdexec::ensure_started_t, const stream_scheduler& sch, S&& sndr) noexcept {
          return ensure_started_th<S>((S&&) sndr, sch.hub_);
        }

      template <stdexec::__one_of<
                  stdexec::let_value_t, 
                  stdexec::let_stopped_t, 
                  stdexec::let_error_t> Let, 
                stdexec::sender S, 
                class Fn>
        friend let_xxx_th<Let, S, Fn>
        tag_invoke(Let, const stream_scheduler& sch, S&& sndr, Fn fun) noexcept {
          return let_xxx_th<Let, S, Fn>{{}, (S &&) sndr, (Fn &&) fun};
        }

      template <stdexec::sender S, class Fn>
        friend upon_error_sender_th<S, Fn>
        tag_invoke(stdexec::upon_error_t, const stream_scheduler& sch, S&& sndr, Fn fun) noexcept {
          return upon_error_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
        }

      template <stdexec::sender S, class Fn>
        friend upon_stopped_sender_th<S, Fn>
        tag_invoke(stdexec::upon_stopped_t, const stream_scheduler& sch, S&& sndr, Fn fun) noexcept {
          return upon_stopped_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
        }

      template <stdexec::sender... Senders>
        friend auto
        tag_invoke(stdexec::transfer_when_all_t, const stream_scheduler& sch, Senders&&... sndrs) noexcept {
          return transfer_when_all_sender_th<stream_scheduler, Senders...>(sch.hub_, (Senders&&)sndrs...);
        }

      template <stdexec::sender... Senders>
        friend auto
        tag_invoke(stdexec::transfer_when_all_with_variant_t, const stream_scheduler& sch, Senders&&... sndrs) noexcept {
          return 
            transfer_when_all_sender_th<stream_scheduler, stdexec::tag_invoke_result_t<stdexec::into_variant_t, Senders>...>(
                sch.hub_, 
                stdexec::into_variant((Senders&&)sndrs)...);
        }

      template <stdexec::sender S, stdexec::scheduler Sch>
        friend auto
        tag_invoke(stdexec::transfer_t, const stream_scheduler& sch, S&& sndr, Sch&& scheduler) noexcept {
          return stdexec::schedule_from((Sch&&)scheduler, transfer_sender_th<S>(sch.hub_, (S&&)sndr));
        }

      template <stdexec::sender S>
        friend split_sender_th<S>
        tag_invoke(stdexec::split_t, const stream_scheduler& sch, S&& sndr) noexcept {
          return split_sender_th<S>((S&&)sndr, sch.hub_);
        }

      friend sender_t tag_invoke(stdexec::schedule_t, const stream_scheduler& self) noexcept {
        return {self.hub_};
      }

      friend std::true_type tag_invoke(stdexec::__has_algorithm_customizations_t, const stream_scheduler& self) noexcept {
        return {};
      }

      template <stdexec::sender S>
        friend auto
        tag_invoke(stdexec::sync_wait_t, const stream_scheduler& self, S&& sndr) {
          return sync_wait::sync_wait_t{}(self.hub_, (S&&)sndr);
        }

      friend stdexec::forward_progress_guarantee tag_invoke(
          stdexec::get_forward_progress_guarantee_t,
          const stream_scheduler&) noexcept {
        return stdexec::forward_progress_guarantee::weakly_parallel;
      }

      bool operator==(const stream_scheduler&) const noexcept = default;

      stream_scheduler(const queue::task_hub_t* hub)
        : hub_(const_cast<queue::task_hub_t*>(hub)) {
      }

    // private: TODO
      queue::task_hub_t* hub_{};
    };

    template <stream_completing_sender Sender>
      void tag_invoke(stdexec::start_detached_t, Sender&& sndr) noexcept(false) {
        submit::submit_t{}((Sender&&)sndr, start_detached::detached_receiver_t{});
      }

    template <stream_completing_sender... Senders>
      when_all_sender_th<stream_scheduler, Senders...>
      tag_invoke(stdexec::when_all_t, Senders&&... sndrs) noexcept {
        return when_all_sender_th<stream_scheduler, Senders...>{nullptr, (Senders&&)sndrs...};
      }

    template <stream_completing_sender... Senders>
      when_all_sender_th<stream_scheduler, stdexec::tag_invoke_result_t<stdexec::into_variant_t, Senders>...>
      tag_invoke(stdexec::when_all_with_variant_t, Senders&&... sndrs) noexcept {
        return when_all_sender_th<stream_scheduler, stdexec::tag_invoke_result_t<stdexec::into_variant_t, Senders>...>{
          nullptr, 
          stdexec::into_variant((Senders&&)sndrs)...
        };
      }

    template <stdexec::sender S, class Fn>
      upon_error_sender_th<S, Fn>
      tag_invoke(stdexec::upon_error_t, S&& sndr, Fn fun) noexcept {
        return upon_error_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
      }

    template <stdexec::sender S, class Fn>
      upon_stopped_sender_th<S, Fn>
      tag_invoke(stdexec::upon_stopped_t, S&& sndr, Fn fun) noexcept {
        return upon_stopped_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
      }
  }

  using STDEXEC_STREAM_DETAIL_NS::stream_scheduler;

  struct stream_context {
    STDEXEC_STREAM_DETAIL_NS::queue::task_hub_t hub{};

    stream_scheduler get_scheduler() {
      return {&hub};
    }
  };
}

