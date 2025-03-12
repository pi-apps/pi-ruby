Gem::Specification.new do |s|
  s.name        = "pinetwork"
  s.version     = "0.1.6"
  s.summary     = "Pi Network Ruby"
  s.description = "Pi Network backend library for Ruby-based web servers."
  s.authors     = ["Pi Core Team"]
  s.email       = "support@minepi.com"
  s.files       = [
    "lib/pinetwork.rb",
    "lib/errors.rb",
    "test/a2u_concurrency_test.rb",
    "test/transaction_submission_test.rb",
    "Rakefile"
  ]
  s.homepage    = "https://github.com/pi-apps/pi-ruby"
  s.license     = "PiOS"
  s.add_runtime_dependency "stellar-sdk", "~> 0.31.0"
  s.add_runtime_dependency "faraday", "~> 1.6.0"
  s.add_development_dependency "minitest", "~> 5.25.4"
  s.add_development_dependency "mocha", "~> 2.7.1"
  s.metadata = {
    "documentation_uri" => "https://github.com/pi-apps/pi-ruby",
  }
end
