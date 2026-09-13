require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
end

require 'json'
require 'logger'
require 'minitest/autorun'
require 'stringio'
require 'webmock/minitest'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'payment_engine'

class LogSink
  attr_reader :events

  def initialize
    @events = []
  end

  def info(message)
    @events << JSON.parse(message, symbolize_names: true)
  end
end

WebMock.disable_net_connect!
