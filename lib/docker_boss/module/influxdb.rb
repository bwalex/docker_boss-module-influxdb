require 'docker_boss'
require 'docker_boss/module'
require 'thread'
require 'celluloid'
require 'timers'
require 'net/http'
require 'uri'
require 'cgi'

class DockerBoss::Module::InfluxDB < DockerBoss::Module
  def initialize(config)
    @config = config
    @mutex = Mutex.new
    @containers = []
    docker_cg = File.exists? "#{config['cgroup_path']}/blkio/docker"
    @config['docker_cg'] = docker_cg

    @pool = Worker.pool(args: [@config])
    DockerBoss.logger.debug "influxdb: Set up to connect to #{@config['server']['protocol']}://[#{@config['server']['host']}]:#{@config['server']['port']}"
    @timers = Timers::Group.new
  end

  def connection
    @http ||= begin
      raise ArgumentError, "Unknown InfluxDB protocol #{@config['server']['protocol']}" unless ['http', 'https'].include? @config['server']['protocol']
      http = Net::HTTP.new(@config['server']['host'], @config['server']['port'])
      http.use_ssl = @config['server']['protocol'] == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @config['server'].fetch('no_verify', false)
      http
    end
  end

  def do_query(q)
    request = Net::HTTP::Get.new("/db/#{@config['database']}/series?q=#{CGI.escape(q)}")
    request.basic_auth @config['server']['user'], @config['server']['pass']
    connection.request(request)
  end

  def test_connection!
    response = do_query('list series')
    raise Error.new response.body unless response.kind_of? Net::HTTPSuccess
    DockerBoss.logger.debug "influxdb: Connection tested successfully"
  end

  def do_post!(data)
    request = Net::HTTP::Post.new("/db/#{@config['database']}/series?time_precision=s")
    request.basic_auth @config['server']['user'], @config['server']['pass']
    request.add_field('Content-Type', 'application/json')
    request.body = data.to_json
    response = connection.request(request)
    raise Error.new response.body unless response.kind_of? Net::HTTPSuccess
  end

  def run
    test_connection!

    @timers.every(@config['interval']) { sample }

    Thread.new do
      loop { @timers.wait }
    end
  end

  def trigger(containers, trigger_id)
    @mutex.synchronize {
      @containers = containers
    }
  end

  def sample
    containers = []

    @mutex.synchronize {
      containers = @containers.map { |c| { id: c['Id'], name: c['Name'][1..-1] } }
    }

    futures = containers.map { |c| @pool.future :sample_container, c }

    do_post! futures.map { |f| f.value }
  end

  class Error < StandardError
  end

  class Worker
    include Celluloid

    def initialize(config)
      @config = config
    end

    def build_path(id, type, file)
      if @config['docker_cg']
        "#{@config['cgroup_path']}/#{type}/docker/#{id}/#{file}"
      else
        "#{@config['cgroup_path']}/#{type}/system.slice/docker-#{id}.scope/#{file}"
      end
    end

    def sample_container(container)
      time_now = Time.now.to_i
      data = { time: time_now }

      kv_sample(container[:id], 'memory', 'memory.stat', 'memory') { |k,v| data[k] = v }
      kv_sample(container[:id], 'cpuacct', 'cpuacct.stat', 'cpuacct') { |k,v| data[k] = v }
      ['blkio.io_serviced', 'blkio.io_service_bytes',
       'blkio.io_wait_time', 'blkio.io_service_time', 'blkio.io_queued'].each do |f|
        blkio_sample(container[:id], 'blkio', f, f.gsub(/\./, '_')) { |k,v| data[k] = v }
      end
      ['blkio.sectors'].each do |f|
        blkio_v_sample(container[:id], 'blkio', f, f.gsub(/\./, '_')) { |k,v| data[k] = v }
      end

      name = container[:name].empty? ? container[:id] : container[:name]

      {
        name:           "#{@config['prefix']}#{name}",
        columns:        data.keys,
        points:         [ data.values ]
      }
    end

    def kv_sample(id, type, file, key_prefix)
      return to_enum(:kv_sample, id, type, file, key_prefix) unless block_given?

      File.readlines(build_path(id, type, file)).each do |line|
        (k,v) = line.chomp.split(/\s+/, 2)
        yield "#{key_prefix}_#{k.downcase}", v.to_i
      end
    end

    def blkio_sample(id, type, file, key_prefix)
      return to_enum(:blkio_sample, id, type, file, key_prefix) unless block_given?
      data = {}

      File.readlines(build_path(id, type, file)).each do |line|
        (maj_min,k,v) = line.chomp.split(/\s+/, 3)
        if maj_min != 'Total'
          data["#{key_prefix}_#{k.downcase}"] ||= 0
          data["#{key_prefix}_#{k.downcase}"] += v.to_i
        end
      end

      data.each { |k,v| yield k, v }
    end

    def blkio_v_sample(id, type, file, key)
      return to_enum(:blkio_v_sample, id, type, file, key) unless block_given?
      data = {}

      File.readlines(build_path(id, type, file)).each do |line|
        (maj_min,v) = line.chomp.split(/\s+/, 2)
        data[key] ||= 0
        data[key] += v.to_i
      end

      data.each { |k,v| yield k, v }
    end
  end
end
