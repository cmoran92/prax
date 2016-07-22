require 'timeout'

module Prax
  class Application
    include Timeout

    attr_reader :app_name, :pid, :port, :workers, :available_workers
    alias name app_name

    class AppWorker
      attr_reader :socket_path

      def initialize(app)
        @app = app
        @worker_number = app.next_worker_number
        @socket_path = File.join(Config.socket_root, "#{File.basename(app.realpath)}-#{@worker_number}.sock")
        Prax.logger.info "Spawning application '#{app.app_name}' [#{app.realpath}]"
        Prax.logger.debug command.inspect

        start

        app.workers << self
        app.available_workers << self

        Prax.logger.debug "Application '#{app.app_name}-#{@worker_number}' is ready on unix:#{socket_path}"
      end

      def kill(type = :TERM, wait = true)
        Prax.logger.debug("Killing #{@app.app_name}-#{@worker_number} (#{@pid})...")
        Process.kill(type.to_s, @pid)

        if wait
          Process.wait(@pid)
        else
          Process.detach(@pid)
        end
      rescue Errno::ECHILD
      ensure
        @app.workers.delete self
        @app.available_workers.delete self
      end

      def socket
        begin
          UNIXSocket.new(socket_path)
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          force_restart
          UNIXSocket.new(socket_path)
        end
      end

      def started?
        File.exists?(socket_path)
      end
    
      private

      def command
        @command ||= [Config.racker_path, "--server", @socket_path]
      end

      def wait_for_process
        timeout(30, CantStartApp) do
          sleep 0.01 while process_exists? && !started?
        end
      end

      def process_exists?
        @pid ? Process.getpgid(@pid) : nil
      rescue Errno::ESRCH
        false
      end

      def force_restart
        Prax.logger.info "Forcing restart of #{@app.app_name}-#{@worker_number} (#{socket_path})"
        kill
        clean_stalled_socket
        start
      end

      def start
        @pid = Process.spawn(env, *command,
          chdir: @app.realpath,
          out: [@app.log_path, 'a'],
          err: :out,
          unsetenv_others: true,
          close_others: true
        )
        wait_for_process
      end

      def clean_stalled_socket
        return unless File.exists?(socket_path)
        Prax.logger.warn("Cleaning stalled socket: #{socket_path}")
        File.unlink(socket_path)
      end

      def env
        { 'PATH' => ENV['ORIG_PATH'], 'PRAX_DEBUG' => ENV['PRAX_DEBUG'], 'HOME' => ENV['HOME'] }
      end
    end

    def self.exists?(app_name)
      File.exists?(File.join(Config.host_root, app_name))
    end

    def initialize(app_name)
      @app_name = app_name.to_s
      @last_worker_number = 0
      @workers = []
      @available_workers = []
      raise NoSuchApp.new unless configured?
    end

    def next_worker_number
      @last_worker_number += 1
    end

    def start
      Prax.logger.info "Starting application #{app_name} (#{object_id})"
      Prax.logger.debug "Workers: #{@workers}"
      spawn unless @workers.detect(&:started?)
    end

    def kill(type = :TERM, wait = true)
      return if port_forwarding?

      @workers.each(&:kill)
    end

    def socket
      Prax.logger.debug "Getting socket for #{app_name} (#{object_id})"
      if port_forwarding?
        begin
          return TCPSocket.new('localhost', @port)
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET
          raise PortForwardingConnectionError.new
        end
      end

      next_worker.socket
    end

    def restart?
      return false if port_forwarding?
      return true unless @workers.detect(&:started?)
      return true if File.exists?(File.join(realpath, 'tmp', 'always_restart.txt'))

      restart = File.join(realpath, 'tmp', 'restart.txt')
      File.exists?(restart) && workers.detect{|w| File.stat(w.socket_path).mtime < File.stat(restart).mtime }
    end

    def configured?
      if File.exists?(path)
        if File.symlink?(path) || File.directory?(path)
          # rack app
          return File.directory?(realpath)
        else
          # port forwarding
          port = File.read(path).strip.to_i
          if port > 0
            @port = port
            return true
          end
        end
      end
      return false
    end

    def port_forwarding?
      !!@port
    end

    def socket_path
      next_worker.socket_path
    end

    def log_path
      @log_path ||= File.join(Config.log_root, "#{File.basename(realpath)}.log")
    end

    def realpath
      @realpath ||= File.realpath(path)
    end

    private

    def next_worker
      available_workers.first
    end

      def spawn
        Prax.logger.info "Spawning one worker for application #{app_name} (#{object_id})"
        AppWorker.new(self)
      end

      def path
        @path ||= File.join(Config.host_root, app_name)
      end

      def gemfile?
        File.exists?(File.join(realpath, 'Gemfile'))
      end
  end
end
