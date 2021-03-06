#!/usr/bin/env ruby

require "em/filetail"
require "eventmachine"
require "logger"
require "set"

EventMachine.epoll if EventMachine.epoll?
EventMachine.kqueue = true if EventMachine.kqueue?

# A file glob pattern watcher for EventMachine.
#
# If you are unfamiliar with globs, see Wikipedia:
# http://en.wikipedia.org/wiki/Glob_(programming)
#
# Any glob supported by Dir#glob will work with
# this class.
#
# This class will allow you to get notified whenever a file
# is created or deleted that matches your glob.
#
# If you are subclassing, here are the methods you should implement:
#    file_found(path)
#    file_deleted(path)
#
# See alsoe
# * EventMachine::watch_glob
# * EventMachine::FileGlobWatch#file_found
# * EventMachine::FileGlobWatch#file_deleted
#
class EventMachine::FileGlobWatch
  # Watch a glob
  #
  # * glob - a string path or glob, such as "/var/log/*.log"
  # * interval - number of seconds between scanning the glob for changes
  def initialize(glob, interval=60)
    @glob = glob
    @files = Set.new
    @watches = Hash.new
    @logger = Logger.new(STDOUT)
    @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)

    # We periodically check here because it is easier than writing our own glob
    # parser (so we can smartly watch globs like /foo/*/bar*/*.log)
    #
    # Reasons to fix this -
    # This will likely perform badly on globs that result in a large number of
    # files.
    EM.next_tick do
      find_files
      EM.add_periodic_timer(interval) do
        find_files
      end
    end # EM.next_tick
  end # def initialize

  # This method is called when a new file is found
  #
  # * path - the string path of the file found
  #
  # You must implement this in your subclass or module for it
  # to work with EventMachine::watch_glob
  public
  def file_found(path)
    raise NotImplementedError.new("#{self.class.name}#file_found is not "\
      "implemented. Did you forget to implement this in your subclass or "\
      "module?")
  end # def file_found

  # This method is called when a file is deleted.
  #
  # * path - the string path of the file deleted
  #
  # You must implement this in your subclass or module for it
  # to work with EventMachine::watch_glob
  public
  def file_deleted(path)
    raise NotImplementedError.new("#{self.class.name}#file_found is not "\
      "implemented. Did you forget to implement this in your subclass or "\
      "module?")
  end # def file_found

  private
  def find_files
    @logger.info("Searching for files in #{@glob}")
    list = Set.new(Dir.glob(@glob))
    list.each do |path|
      next if @files.include?(path)
      add(path)
    end

    (@files - list).each do |missing|
      remove(missing)
    end
  end # def find_files

  # Remove a file from being watched and notify file_deleted()
  private
  def remove(path)
    @files.delete(path)
    @watches.delete(path)
    file_deleted(path)
  end # def remove

  # Add a file to watch and notify file_found()
  private
  def add(path)
    @files.add(path)

    # If EventMachine::watch_file fails, that's ok, I guess.
    # We'll still find the file 'missing' from the next glob attempt.
    #begin
      # EM currently has a bug that only the first handler for a watch_file
      # on each file gets events. This causes globtails to never get data 
      # since the glob is watching the file already.
      # Until we fix that, let's skip file watching here.
      #@watches[path] = EventMachine::watch_file(path, FileWatcher, self) do |path|
      #  remove(path)
      #end
    #rescue Errno::EACCES => e
      #@logger.warn(e)
    #end
    file_found(path)
  end # def watch

  private
  class FileWatcher < EventMachine::FileWatch
    def initialize(globwatch, &block)
      @globwatch = globwatch
      @block = block
    end

    def file_moved
      stop_watching
      block.call path
    end

    def file_deleted
      block.call path
    end
  end # class EventMachine::FileGlobWatch::FileWatcher < EventMachine::FileWatch
end # class EventMachine::FileGlobWatch

# A glob tailer for EventMachine
#
# This class combines features of EventMachine::file_tail and 
# EventMachine::watch_glob.
#
# You won't generally subclass this class (See EventMachine::FileGlobWatch)
#
# See also: EventMachine::glob_tail
#
class EventMachine::FileGlobWatchTail < EventMachine::FileGlobWatch
  # Initialize a new file glob tail.
  #
  # path should be a glob or file path.
  # handler should be a module or subclass of EventMachine::FileTail
  #   See also EventMachine::file_tail
  # interval is how often (seconds) the glob path should be scanned
  # exclude is an array of Regexp (or anything with .match) for 
  #   excluding from things to tail
  # The remainder of arguments are passed to EventMachine::file_tail as
  #   EventMachine::file_tail(path_found, handler, *args)
  public
  def initialize(path, handler=nil, interval=60, exclude=[], *args)
    super(path, interval)
    @handler = handler
    @args = args
    @exclude = exclude
  end # def initialize

  public
  def file_found(path)
    begin
      @logger.info "#{self.class}: Trying #{path}"
      @exclude.each do |exclude|
        @logger.info "#{self.class}: Testing #{exclude} =~ #{path} == #{exclude.match(path) != nil}"
        if exclude.match(path) != nil
          file_excluded(path) 
          return
        end
      end
      @logger.info "#{self.class}: Watching #{path}"

      EventMachine::file_tail(path, @handler, *@args)
    rescue Errno::EACCES => e
      file_error(path, e)
    rescue Errno::EISDIR => e
      file_error(path, e)
    end 
  end # def file_found

  public
  def file_excluded(path)
    @logger.info "#{self.class}: Skipping path #{path} due to exclude rule"
  end # def file_excluded

  public
  def file_deleted(path)
    # Nothing to do
  end # def file_deleted

  public
  def file_error(path, e)
    $stderr.puts "#{e.class} while trying to tail #{path}"
    # otherwise, drop the error by default
  end # def file_error
end # class EventMachine::FileGlobWatchHandler

module EventMachine
  # Watch a glob and tail any files found.
  #
  # 'glob' should be a string path or glob, such as /var/log/*.log
  # handler must be a module or subclass of EventMachine::FileGlobWatchTail
  #   See EventMachine::FileGlobWatchTail for the callback methods.
  def self.glob_tail(glob, handler=nil, *args)
    handler = EventMachine::FileGlobWatch if handler == nil
    args.unshift(glob)
    klass = klass_from_handler(EventMachine::FileGlobWatchTail, handler, *args)
    c = klass.new(*args)
    yield c if block_given?
    return c
  end 

  # Watch a glob for any files.
  #
  # * glob - a string path or glob, such as "/var/log/*.log"
  # * handler - must be a module or a subclass of EventMachine::FileGlobWatch
  # 
  # The remaining (optional) arguments are passed to your handler like this:
  #   If you call this:
  #     EventMachine.watch_glob("/var/log/*.log", YourHandler, 1, 2, 3, ...)
  #   This will be invoked when new matching files are found:
  #     YourHandler.new(path_found, 1, 2, 3, ...)
  #     ^ path_found is the new path found by the glob
  #
  # See EventMachine::FileGlobWatch for the callback methods.
  def self.watch_glob(glob, handler=nil, *args)
    # This code mostly styled on what EventMachine does in many of it's other
    # methods.
    args = [glob, *args]
    klass = klass_from_handler(EventMachine::FileGlobWatch, handler, *args);
    c = klass.new(*args)
    yield c if block_given?
    return c
  end # def EventMachine::watch_glob
end # module EventMachine
