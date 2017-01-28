require "prax/request"
require "prax/response"
require "prax/render"
require "prax/public_file"

module Prax
  class Handler
    include Render

    attr_reader :request, :socket, :ssl

    def initialize(socket, ssl = nil)
      @socket, @ssl = socket, ssl
    end

    def handle
      if request.uri
        file = PublicFile.new(request, app_name)
        if file.exists?
          file.stream_to(socket)
        else
          app.with_socket do |connection|
            @connection = connection
            request.proxy_to(connection)  # socket => connection
            response.proxy_to(socket)     # socket <= connection
          end
        end
      end

    rescue CantStartApp
      if app.is_a? PortForwardingApplication
        render :port_forwarding_connection_error, status: 500
      else
        render :cant_start_app, status: 500
      end

    rescue NoSuchApp
      render :no_such_app, status: 404

    rescue BadRequest => ex
      @message = ex.message
      render :bad_request, status: 400

    rescue PortForwardingConnectionError
      render :port_forwarding_connection_error, status: 500

    rescue Timeout::Error
      render :timeout, status: 500

    ensure
      socket.close unless socket.closed?
    end

    def request
      @request ||= Request.new(socket, ssl)
    end

    def response
      @response ||= Response.new(connection)
    end

    def connection
      @connection ||= app.socket
    end

    def app
      @app ||= Spawner.get(app_name)
    end

    def app_name
      @app_name ||= if request.host.ip?
                      :default
                    elsif request.host.xip?
                      Application.name_for(request.xip_host)
                    else
                      Application.name_for(request.host)
                    end
    end
  end
end
