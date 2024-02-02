Gem::Specification.new do |s|
  s.name        = "pinetwork"
  s.version     = "0.1.2"
  s.summary     = "Pi Network Ruby"
  s.description = "Pi Network backend library for Ruby-based webservers."
  s.authors     = ["Pi Core Team"]
  s.email       = "support@minepi.com"
  s.files       = ["lib/pi_network.rb", "lib/errors.rb"]
  s.homepage    = "https://github.com/pi-apps/pi-ruby"
  s.license     = "PiOS"
  s.add_runtime_dependency "stellar-sdk", "~> 0.29.0"
  s.add_runtime_dependency "faraday", "~> 0"
  s.metadata = {
    "documentation_uri" => "https://github.com/pi-apps/pi-ruby",
  }
end
