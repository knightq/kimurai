module Kimurai
  class Runner
    attr_reader :jobs, :crawlers

    def initialize(parallel_jobs:)
      @jobs = parallel_jobs
      @crawlers = Base.descendants.select { |crawler_class| crawler_class.name != nil }

      if timezone = Kimurai.configuration.timezone
        Kimurai.timezone = timezone
      end

      require 'kimurai/stats' if Kimurai.configuration.stats
    end

    def run!
      start_time = Time.now
      session_id = start_time.to_i

      ENV.store("LOG_TO_FILE", "true")
      ENV.store("SESSION_ID", session_id.to_s)

      session_info = {
        id: session_id,
        status: :processing,
        start_time: start_time,
        stop_time: nil,
        concurrent_jobs: jobs,
        crawlers: crawlers.map(&:name)
      }

      # define at exit first, in case if at_start_callback will fail
      at_exit do
        # in ruby all at_exits in forks executed as well.
        # don't call at exit body if process is fork.
        # here, Parallel.worker_number will be nil in parent process, but will have number
        # if process is fork.
        if Parallel.worker_number.nil?
          # if process was interrupted, $! will not be a nil
          error = $!
          stop_time = Time.now

          if error.nil?
            session_info.merge!(status: :completed, stop_time: stop_time)
          else
            # maybe fix to status == stopped or interrupted
            session_info.merge!(status: :failed, error: error.inspect, stop_time: stop_time)
          end

          puts ">> Runner: stopped session: #{session_info}"
          update_session(session_info) if Kimurai.configuration.stats
          if at_stop_callback = Kimurai.configuration.runner_at_stop_callback
            at_stop_callback.call(session_info)
          end
        end
      end

      puts ">> Runner: started session: #{session_info}"
      register_session(session_info) if Kimurai.configuration.stats
      if at_start_callback = Kimurai.configuration.runner_at_start_callback
        at_start_callback.call(session_info)
      end

      at_crawler_start = ->(item, i) { puts "> Runner: started crawler: #{item.name}, index: #{i + 1}" }
      at_crawler_finish = lambda do |item, i, result|
        status = result.nil? ? :failed : result
        puts "< Runner: stopped crawler: #{item.name}, index: #{i + 1}, status: #{status}"
      end

      options = { in_processes: jobs, isolation: true, start: at_crawler_start, finish: at_crawler_finish }
      Parallel.each(crawlers, options) do |crawler_class|
        crawler_class.start
      rescue => e
        # Failed crawler
      end
    end

    private

    def register_session(session_info)
      Stats::Session.create(session_info)
    end

    def update_session(session_info)
      session = Stats::Session.find(session_info[:id]).first
      session.set(session_info)
      session.save
    end
  end
end