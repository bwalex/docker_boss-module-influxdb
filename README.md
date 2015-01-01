# DockerBoss::Module::InfluxDB

TODO: Write a gem description

## Installation

Add this line to your application's Gemfile:

    gem 'docker_boss-module-influxdb'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install docker_boss-module-influxdb

## Usage

Example yaml:

```yaml
influxdb:
  server:
    protocol: http
    host: localhost
    port: 8086
    user: root
    pass: root
    no_verify: false

  database: db1

  prefix:   container.
  interval: 60

  cgroup_path: /sys/fs/cgroup
```


## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
