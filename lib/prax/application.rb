require 'timeout'

module Prax
  class Application
    include Timeout

    attr_reader :app_name, :pid, :workers, :available_workers
    alias name app_name

    def self.name_for(fqdn)
      segments = fqdn.split('.')
      (segments.size - 1).times do |index|
        app_name = segments[index...-1].join('.')
        return app_name if File.exists?(path(app_name))
      end
      :default
    end

    def self.path(name)
      File.join(Config.host_root, name)
    end
    private_class_method :path

    def self.for(name)
      if File.exists?(_path = path(name))
        if File.symlink?(_path)
          __path = File.realpath(_path) if File.symlink?(_path)
          unless File.exists?(_path)
            Prax.logger.error "Dangling symlink from #{_path} to #{__path}"
            raise NoSuchApp.new
          end
          _path = __path
        end
        if File.directory?(_path)
          return RackApplication.new(_path)
        else
          port = File.read(_path).strip.to_i
          if port > 0
            return PortForwardingApplication.new(name, port)
          else
            Prax.logger.error "Could not read port number for #{name} from file at #{_path}"
            raise NoSuchApp.new
          end
        end
      end
    end

    def initialize(name)
      @app_name = name
    end

    def log_path
      @log_path ||= File.join(Config.log_root, "#{@app_name}.log")
    end
  end

  class PortForwardingApplication < Application
    attr_reader :port

    def initialize(name, port)
      @port = port
      super(name)
    end

    def start; end
    def kill; end
    def restart?; false; end

    def socket
      Prax.logger.debug "Getting socket for app #{name} (#{object_id})"
      begin
        return TCPSocket.new('localhost', @port)
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        raise PortForwardingConnectionError.new
      end
    end
  end

  class RackApplication

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
      @workers.each(&:kill)
    end

    def socket
      Prax.logger.debug "Getting socket for #{app_name} (#{object_id})"
      next_worker.socket
    end

    def restart?
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

    def socket_path
      next_worker.socket_path
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
