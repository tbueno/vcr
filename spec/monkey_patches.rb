module MonkeyPatches
  extend self

  NET_HTTP_SINGLETON = class << Net::HTTP; self; end

  NET_HTTP_MONKEY_PATCHES = [
    [Net::BufferedIO,    :initialize],
    [Net::HTTP,          :request],
    [Net::HTTP,          :connect],
    [NET_HTTP_SINGLETON, :socket_type]
  ]

  ALL_MONKEY_PATCHES = NET_HTTP_MONKEY_PATCHES.dup

  def enable!(scope)
    case scope
      when :webmock
        ::WebMock.reset!
        ::WebMock::HttpLibAdapters::NetHttpAdapter.enable!
        ::WebMock::HttpLibAdapters::TyphoeusAdapter.enable! if defined?(::Typhoeus)
        $original_webmock_callbacks.each do |cb|
          ::WebMock::CallbackRegistry.add_callback(cb[:options], cb[:block])
        end
      when :vcr
        realias Net::HTTP, :request, :with_vcr
      else raise ArgumentError.new("Unexpected scope: #{scope}")
    end
  end

  def disable_all!
    realias_all :without_monkeypatches

    if defined?(::WebMock::HttpLibAdapters)
      ::WebMock::HttpLibAdapters::NetHttpAdapter.disable!
      ::WebMock::HttpLibAdapters::TyphoeusAdapter.disable! if defined?(::Typhoeus)
      ::WebMock::CallbackRegistry.reset
      ::WebMock::StubRegistry.instance.request_stubs = []
    end

    if defined?(::Typhoeus.before)
      ::Typhoeus.on_complete.clear
      ::Typhoeus.before.clear
    elsif defined?(::Typhoeus::Hydra)
      ::Typhoeus::Hydra.clear_global_hooks
      ::Typhoeus::Hydra.stub_finders.clear
    end
  end

  def init
    # capture the monkey patched definitions so we can realias to them in the future
    ALL_MONKEY_PATCHES.each do |mp|
      capture_method_definition(mp.first, mp.last, false)
    end
  end

  private

  def capture_method_definition(klass, method, original)
    klass.class_eval do
      monkeypatch_methods = [:vcr, :fakeweb].select { |m| method_defined?(:"#{method}_with_#{m}") }

      if original
        if monkeypatch_methods.size > 0
          raise "The following monkeypatch methods have already been defined #{method}: #{monkey_patch_methods.inspect}"
        end
        alias_name = :"#{method}_without_monkeypatches"
      else
        alias_name = :"#{method}_with_monkeypatches"
      end

      alias_method alias_name, method
    end
  end

  # capture the original method definitions before the monkey patches have been defined
  # so we can realias to the originals in the future
  ALL_MONKEY_PATCHES.each do |mp|
    capture_method_definition(mp.first, mp.last, true)
  end

  def realias(klass, method, alias_extension)
    klass.class_eval do
      old_verbose, $VERBOSE = $VERBOSE, nil
      alias_method method, :"#{method}_#{alias_extension}"
      $VERBOSE = old_verbose
    end
  end

  def realias_all(alias_extension)
    ALL_MONKEY_PATCHES.each do |mp|
      realias mp.first, mp.last, alias_extension
    end
  end

  def realias_net_http(alias_extension)
    NET_HTTP_MONKEY_PATCHES.each do |mp|
      realias mp.first, mp.last, alias_extension
    end
  end
end

# Require all the HTTP libraries--these must be required before WebMock
# for WebMock to work with them.
require 'httpclient'

unless RUBY_INTERPRETER == :jruby
  require 'patron'
  require 'em-http-request'
  require 'curb'
end


# All Net::HTTP monkey patches have now been loaded, so capture the
# appropriate method definitions so we can disable them later.
MonkeyPatches.init

# Disable FakeWeb/VCR Net::HTTP patches before WebMock
# subclasses Net::HTTP and inherits them...
MonkeyPatches.disable_all!

require 'vcr/library_hooks/webmock'
$original_webmock_callbacks = ::WebMock::CallbackRegistry.callbacks

# disable all by default; we'll enable specific ones when we need them
MonkeyPatches.disable_all!

RSpec.configure do |config|
  [:fakeweb, :webmock, :vcr].each do |scope|
    config.before(:all, :with_monkey_patches => scope) { MonkeyPatches.enable!(scope) }
    config.after(:all,  :with_monkey_patches => scope) { MonkeyPatches.disable_all!   }
  end
end

