require 'yaml'
require 'new_relic/local_environment'
require 'singleton'
require 'erb'
require 'net/https'
require 'new_relic/local_environment'
require 'logger'


module NewRelic 
  
# The Control is a singleton responsible for the startup and
# initialization sequence.  The initializer uses a LocalEnvironment to 
# detect the framework and instantiates the framework specific
# subclass.
#
# The Control also implements some of the public API for the agent.
# 
  class Control
    
    attr_accessor :log_file, :env
    attr_reader :local_env
    
    # Structs holding info for the remote server and proxy server 
    class Server < Struct.new :host, :port #:nodoc:
      def to_s; "#{host}:#{port}"; end
    end
    
    ProxyServer = Struct.new :host, :port, :user, :password #:nodoc:

    # Access the Control singleton, lazy initialized
    def self.instance
      @instance ||= new_instance
    end
    
    # Initialize the plugin/gem and start the agent.  This does the necessary configuration based on the
    # framework environment and determines whether or not to start the agent.  If the
    # agent is not going to be started then it loads the agent shim which has stubs
    # for all the external api.
    #
    # This may be invoked multiple times, as long as you don't attempt to uninstall
    # the agent after it has been started.
    #
    # If the plugin is initialized and it determines that the agent is not enabled, it 
    # will skip starting it and install the shim.  But if you later call this with 
    # <tt>:agent_enabled => true</tt>, then it will install the real agent and start it.
    #
    # What determines whether the agent is launched is the result of calling agent_enabled?
    # This will indicate whether the instrumentation should/will be installed.  If we're
    # in a mode where tracers are not installed then we should not start the agent.
    #
    # Subclasses are not allowed to override, but must implement init_config({}) which
    # is called at most once.
    #
    def init_plugin(options={})
      require 'new_relic/agent'
      # Merge the stringified options into the config as overrides:
      options.each { |sym, val | self[sym.to_s] = val unless sym == :config }
      init_config(options)
      if agent_enabled? && !@started
        setup_log
        start_agent
        install_instrumentation
        local_env.gather_environment_info
        append_environment_info
        @started = true
      elsif !agent_enabled?
        install_shim
      end
    end
    
    # Install the real agent into the Agent module, and issue the start command.
    def start_agent
      NewRelic::Agent.agent = NewRelic::Agent::Agent.instance
      NewRelic::Agent.agent.start
    end
    
    def [](key)
      fetch(key)
    end
    
    def settings
      @settings ||= (@yaml && merge_defaults(@yaml[env])) || {}
    end
    
    def []=(key, value)
      settings[key] = value
    end
    
    def fetch(key, default=nil)
      settings.fetch(key, default)
    end
    # Add your own environment value to track for change detection.
    # The name and value should be stable and not vary across app processes on 
    # the same host.
    def append_environment_info(name, value)
      local_env.record_environment_info(name,value)
    end
    
    ###################################
    # Agent config conveniences
    
    def license_key
      fetch('license_key')
    end
    def capture_params
      fetch('capture_params')
    end
    def newrelic_root
      File.expand_path(File.join(__FILE__, "..","..",".."))
    end
    # True if we are sending data to the server, monitoring production
    def monitor_mode?
      fetch('enabled', nil)
    end
    # True if we are capturing data and displaying in /newrelic
    def developer_mode?
      fetch('developer', nil)
    end
    # True if dev mode or monitor mode are enabled, and we are running
    # inside a valid dispatcher like mongrel or passenger.  Can be overridden
    # by NEWRELIC_ENABLE env variable, monitor_daemons config option when true, or
    # agent_enabled config option when true or false.
    def agent_enabled?
      return false if !developer_mode? && !monitor_mode?
      return self['agent_enabled'].to_s =~ /true|on|yes/i unless self['agent_enabled'].nil?
      return false if ENV['NEWRELIC_ENABLE'].to_s =~ /false|off|no/i 
      return true if self['monitor_daemons'].to_s =~ /true|on|yes/i
      return true if ENV['NEWRELIC_ENABLE'].to_s =~ /true|on|yes/i
      # When in 'auto' mode the agent is enabled if there is a known
      # dispatcher running
      return true if @local_env.dispatcher != nil
    end
    
    def app
      @local_env.framework
    end
    alias framework app
    
    def dispatcher_instance_id
      self['dispatcher_instance_id'] || @local_env.dispatcher_instance_id
    end
    def dispatcher
      self['dispatcher'] || @local_env.dispatcher
    end
    def app_name
      self['app_name']
    end
    
    def use_ssl?
      @use_ssl ||= fetch('ssl', false)
    end
    
    def server
      @remote_server ||= server_from_host(nil)  
    end
    
    def api_server
      @api_server ||= 
      NewRelic::Control::Server.new fetch('api_host', 'rpm.newrelic.com'), fetch('api_port', fetch('port', use_ssl? ? 443 : 80)).to_i
    end
    
    def proxy_server
      @proxy_server ||=
      NewRelic::Control::ProxyServer.new convert_to_ip_address(fetch('proxy_host', nil)), fetch('proxy_port', nil),
      fetch('proxy_user', nil), fetch('proxy_pass', nil)
    end
    
       
    
    def server_from_host(host)
      host ||= fetch('host', 'collector.newrelic.com')
      
      # if the host is not an IP address, turn it into one
      host = convert_to_ip_address(host)
      
      NewRelic::Control::Server.new host, fetch('port', use_ssl? ? 443 : 80).to_i 
    end
    
    # Return the Net::HTTP with proxy configuration given the NewRelic::Control::Server object.
    # Default is the collector but for api calls you need to pass api_server
    def http_connection(host = nil)
      host ||= server
      # Proxy returns regular HTTP if @proxy_host is nil (the default)
      http = Net::HTTP::Proxy(proxy_server.host, proxy_server.port, 
                              proxy_server.user, proxy_server.password).new(host.host, host.port)
      if use_ssl?
        http.use_ssl = true 
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      http
    end
    def to_s
      "Control[#{self.app}]"
    end
    
    def log
      # If we try to get a log before one has been set up, return a stdout log
      unless @log
        l = Logger.new(STDOUT)
        l.level = Logger::WARN
        return l
      end
      @log
    end
    
    # send the given message to STDERR so that it shows
    # up in the console.  This should be used for important informational messages at boot.
    # The to_stderr may be implemented differently by different config subclasses.
    # This will NOT print anything if tracers are not enabled
    def log!(msg, level=:info)
      return if @settings && !agent_enabled?
      to_stderr msg
      log.send level, msg if @log
    end
    
    # Install stubs to the proper location so the app code will not fail
    # if the agent is not running.
    def install_shim
      # Once we install instrumentation, you can't undo that by installing the shim.
      raise "Cannot install the Agent shim after instrumentation has already been installed!" if @instrumented
      NewRelic::Agent.agent = NewRelic::Agent::ShimAgent.instance
      Module.send :include, NewRelic::Agent::MethodTracerShim
    end
    
    def install_instrumentation
      return if @instrumented
      
      @instrumented = true
      
      Module.send :include, NewRelic::Agent::MethodTracer
      
      # Instrumentation for the key code points inside rails for monitoring by NewRelic.
      # note this file is loaded only if the newrelic agent is enabled (through config/newrelic.yml)
      instrumentation_path = File.join(File.dirname(__FILE__), 'agent','instrumentation')
      instrumentation_files = [ ] <<
      File.join(instrumentation_path, '*.rb') <<
      File.join(instrumentation_path, app.to_s, '*.rb')
      instrumentation_files.each do | pattern |
        Dir.glob(pattern) do |file|
          begin
            log.debug "Processing instrumentation file '#{file}'"
            require file
          rescue => e
            log.error "Error loading instrumentation file '#{file}': #{e}"
            log.debug e.backtrace.join("\n")
          end
        end
      end
      
      log.debug "Finished instrumentation"
    end
    
    def load_samplers(agent)
      agent.stats_engine.add_sampler NewRelic::Agent::Samplers::MongrelSampler.new config.mongrel if local_env.mongrel
      agent.stats_engine.add_sampler NewRelic::Agent::Samplers::CpuSampler.new unless defined? Java
      agent.stats_engine.add_sampler NewRelic::Agent::Samplers::MemorySampler.new 
    end
     
    protected

    # Append framework specific environment information for uploading to
    # the server for change detection.  Override in subclasses
    def append_environment_info; end
    
    def convert_to_ip_address(host)
      return nil unless host
        ip_address = host
      unless host.downcase == "localhost"
        begin
          ip_address = Resolv.getaddress(host)
          log.info "Resolved #{host} to #{ip_address}"
        rescue => e
          log.warn "DNS Error caching IP address: #{e}"
        end
      end
      ip_address
    end
    

    def merge_defaults(settings_hash)
      s = {
        'host' => 'collector.newrelic.com',
        'ssl' => false,
        'log_level' => 'info',
        'apdex_t' => 1.0
      }.merge settings_hash
      # monitor_daemons replaced with agent_enabled
      s['agent_enabled'] = s.delete('monitor_daemons') if s['agent_enabled'].nil?
      s
    end
    # Control subclasses may override this, but it can be called multiple times.
    def setup_log
      @log_file = "#{log_path}/newrelic_agent.log"
      @log = Logger.new @log_file
      
      # change the format just for our logger
      
      def @log.format_message(severity, timestamp, progname, msg)
        "[#{timestamp.strftime("%m/%d/%y %H:%M:%S %z")} #{Socket.gethostname} (#{$$})] #{severity} : #{msg}\n" 
      end
    
      # set the log level as specified in the config file
      case fetch("log_level","info").downcase
        when "debug"; @log.level = Logger::DEBUG
        when "info"; @log.level = Logger::INFO
        when "warn"; @log.level = Logger::WARN
        when "error"; @log.level = Logger::ERROR
        when "fatal"; @log.level = Logger::FATAL
      else @log.level = Logger::INFO
      end
      @log
    end
    
    def to_stderr(msg)
      STDERR.puts "** [NewRelic] " + msg 
    end
    
    def config_file
      File.expand_path(File.join(root,"config","newrelic.yml"))
    end
    
    def log_path
      path = File.join(root,'log')
      unless File.directory? path
        path = '.'
      end
      File.expand_path(path)
    end
    
    def log_file_name
      @log_file
    end
    
    # Create the concrete class for environment specific behavior:
    def self.new_instance
      @local_env = NewRelic::LocalEnvironment.new
            case @local_env.framework
        when :test
        require 'config/test_config'
        NewRelic::Control::Test.new @local_env
        when :merb
        require 'new_relic/control/merb'
        NewRelic::Control::Merb.new @local_env
        when :rails
        require 'new_relic/control/rails'
        NewRelic::Control::Rails.new @local_env
      when :ruby
        require 'new_relic/control/ruby'
        NewRelic::Control::Ruby.new @local_env
      else 
        raise "Unknown framework: #{@local_env.framework}"
      end
    end
    
    def initialize local_env
      @local_env = local_env
      newrelic_file = config_file
      # Next two are for populating the newrelic.yml via erb binding, necessary
      # when using the default newrelic.yml file
      generated_for_user = ''
      license_key=''
      if !File.exists?(config_file)
        yml_file = File.expand_path(File.join(__FILE__,"..","..","..","newrelic.yml"))
        yaml = ::ERB.new(File.read(yml_file)).result(binding)
        log! "Cannot find newrelic.yml file at #{config_file}."
        log! "Using #{yml_file} file."
        log! "Signup at rpm.newrelic.com to get a newrelic.yml file configured for a free Lite account."
      else
        yaml = ERB.new(File.read(config_file)).result(binding)
      end
      @yaml = YAML.load(yaml)
    rescue ScriptError, StandardError => e
      puts e
      puts e.backtrace.join("\n")
      raise "Error reading newrelic.yml file: #{e}"
    end
    

  end
end