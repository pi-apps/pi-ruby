Gem::Specification.new do |s|
  s.name        = "pinetwork"
  s.version     = "1.0.0"
  s.summary     = "Pi Network Ruby"
  s.description = "Pi Network backend library for Ruby-based webservers."
  s.authors     = ["Pi Core Team"]
  s.email       = "support@minepi.com"
  s.files       = ["lib/pi_network.rb"]
  s.homepage    = "https://rubygems.org/gems/pi_network"
  s.license     = "PiOS"
  s.add_runtime_dependency "stellar-sdk", "~> 0.29.0"
  s.add_runtime_dependency "faraday", "~> 0"
end
