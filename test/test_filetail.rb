#!/usr/bin/env ruby

require 'rubygems'
$:.unshift "#{File.dirname(__FILE__)}/../lib"
require 'eventmachine-tail'
require 'tempfile'
require 'test/unit'
require 'timeout'
require 'testcase_helpers.rb'


# Generate some data
DATA = (1..10).collect { |i| rand.to_s }
SLEEPMAX = 1

class Reader < EventMachine::FileTail
  def initialize(path, startpos=-1, testobj=nil)
    super(path, startpos)
    @data = DATA.clone
    @buffer = BufferedTokenizer.new
    @testobj = testobj
    @lineno = 0
  end # def initialize

  def receive_data(data)
    @buffer.extract(data).each do |line|
      @lineno += 1
      expected = @data.shift
      @testobj.assert_equal(expected, line, 
          "Expected '#{expected}' on line #{@lineno}, but got '#{line}'")
      @testobj.finish if @data.length == 0
    end # @buffer.extract
  end # def receive_data
end # class Reader

class TestFileTail < Test::Unit::TestCase
  include EventMachineTailTestHelpers

  # This test should run slow. We are trying to ensure that
  # our file_tail correctly reads data slowly fed into the file
  # as 'tail -f' would.
  def test_filetail
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      EM::file_tail(tmp.path, Reader, -1, self)
      timer = EM::PeriodicTimer.new(0.2) do
        tmp.puts data.shift
        tmp.flush
        sleep(rand * SLEEPMAX)
        timer.cancel if data.length == 0
      end
    end # EM.run
  end # def test_filetail

  def test_filetail_with_seek
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    data.each { |i| tmp.puts i }
    tmp.flush
    EM.run do
      abort_after_timeout(2)

      # Set startpos of 0 (beginning of file)
      EM::file_tail(tmp.path, Reader, 0, self)
    end # EM.run
  end # def test_filetail

  def test_filetail_with_block
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      lineno = 0
      EM::file_tail(tmp.path) do |filetail, line|
        lineno += 1
        expected = data.shift
        assert_equal(expected, line, 
                     "Expected '#{expected}' on line #{@lineno}, but got '#{line}'")
        finish if data.length == 0
      end

      data_copy = data.clone
      timer = EM::PeriodicTimer.new(0.2) do
        tmp.puts data_copy.shift
        tmp.flush
        sleep(rand * SLEEPMAX)
        timer.cancel if data_copy.length == 0
      end
    end # EM.run
  end # def test_filetail_with_block
end # class TestFileTail

