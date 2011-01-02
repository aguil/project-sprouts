
module Sprout

  ##
  # The Sprout::Daemon class exposes the Domain Specific Language
  # provided by the Sprout::Executable, along with
  # enhancements (and modifications) to support long-lived processes
  # (like FDB and FCSH).
  #
  #   ##
  #   # The Foo class extends Sprout::Daemon
  #   class Foo < Sprout::Daemon
  #
  #     ##
  #     # Keep in mind that we're still working
  #     # with Executable, so add_param is available
  #     # for the initialization of the process.
  #     add_param :input, File
  #
  #     ##
  #     # Expose the do_something action after
  #     # the process is started.
  #     add_action :do_something
  #
  #     ##
  #     # Expose the do_something_else action after
  #     # the process is started.
  #     add_action :do_something_else
  #   end
  #
  # You can also create a globally-accessible rake task to use
  # your new Daemon instance by creating a method like the following:
  #
  #   def foo *args, &block
  #     foo_tool = Foo.new
  #     foo_tool.to_rake *args, &block
  #   end
  #
  # The previous Rake task could be used like:
  #
  #   foo 'Bar.txt' do |t|
  #     t.do_something
  #     t.do_something_else
  #   end
  #
  class Daemon < Executable::Base

    class << self

      ##
      # Add an action that can be called while
      # the long-lived process is active.
      #
      # This method should raise a Sprout::Errors::UsageError
      # if the provided action name is already defined for 
      # the provided instance.
      #
      # @param name [Symbol, String] The name of the method.
      # @param arguments [Array<Object>] An array of arguments that the method accepts.
      # @param options [Hash] The options hash is reserved for future use.
      #
      #   class Foo < Sprout::Daemon
      #     
      #     add_action :continue
      #
      #     add_action :quit
      #   end
      #
      # @return [nil]
      def add_action name, arguments=nil, options=nil
        options ||= {}
        options[:name] = name
        options[:arguments] = arguments
        create_action_method options
        nil
      end

      ##
      # Create an (often shorter) alias to an existing
      # action name.
      #
      # @return [nil]
      #
      # @see add_action
      def add_action_alias alias_name, source_name
        define_method(alias_name) do |*params|
          self.send(source_name, params)
        end
        nil
      end

      private

      ##
      # Actually create the method for a provided
      # action.
      #
      # This method should explode if the method name
      # already exists.
      def create_action_method options
        name = options[:name]
        accessor_can_be_defined_at name

        define_method(name) do |*params|
          action = name.to_s
          action = "y" if name == :confirm # Convert affirmation
          action << " #{params.join(' ')}" unless params.nil?
          action_stack << action
          execute_actions if process_launched?
        end
      end

      ##
      # TODO: Raise an exception if the name is 
      # already taken?
      def accessor_can_be_defined_at name
      end

    end


    ##
    # The prompt expression for this daemon process.
    #
    # When executing a series of commands, the
    # wrapper will wait until it matches this expression
    # on stdout before continuing the series.
    #
    # For FDB, this value is set like:
    #
    #   set :prompt, /^\(fdb\) /
    #
    # Most processes can trigger a variety of different
    # prompts, these can be expressed here using the | (or) operator.
    #
    # FDB actually uses the following:
    #
    #   set :prompt, /^\(fdb\) |\(y or n\) /
    #
    # @return [Regexp]
    attr_accessor :prompt


    ##
    # The Sprout::ProcessRunner that delegates to the long-running process,
    # via stdin, stdout and stderr.
    attr_reader :process_runner

    ##
    # @return [Array<Hash>] Return or create a new array.
    def action_stack
      @action_stack ||= []
    end

    ##
    # Execute the Daemon executable, followed
    # by the collection of stored actions in 
    # the order they were called.
    #
    # If none of the stored actions result in
    # terminating the process, the underlying
    # daemon will be connected to the terminal
    # for user (manual) input.
    #
    # You can also send wait=false to connect
    # to a daemon process from Ruby and execute
    # actions over time. This might look like:
    #
    #    fdb = FlashSDK::FDB.new
    #    fdb.execute false
    #
    #    # Do something else while FDB
    #    # is open, then:
    #    
    #    fdb.run
    #    fdb.break "AsUnitRunner:12"
    #    fdb.continue
    #    fdb.kill
    #    fdb.confirm
    #    fdb.quit
    #
    # @param wait [Boolean] default true. Send false to
    #   connect to a daemon from Ruby code.
    #
    def execute should_wait=true
      @process_runner = super()
      @process_launched = true
      wait_for_prompt
      execute_actions
      handle_user_session if should_wait
      wait if should_wait
    end

    def wait
      Process.wait process_runner.pid
    rescue Errno::ECHILD
    end

    ##
    # Wait for the underlying process to present
    # an input prompt, so that another action
    # can be submitted, or user input can be
    # collected.
    def wait_for_prompt expected_prompt=nil
      expected_prompt = expected_prompt || prompt

      fake_stderr = Sprout::OutputBuffer.new
      fake_stdout = Sprout::OutputBuffer.new
      stderr = read_from process_runner.e, fake_stderr
      stdout = read_from process_runner.r, fake_stdout, expected_prompt
      stdout.join && stderr.kill

      stdout_str = fake_stdout.read
      stderr_str = fake_stderr.read

      Sprout.stderr.printf(stderr_str)
      Sprout.stdout.printf(stdout_str)
    end

    ##
    # Expose the running process to manual
    # input on the terminal, and write stdout
    # back to the user.
    def handle_user_session
      while !process_runner.r.eof?
        input = $stdin.gets.chomp!
        execute_action input, true
        wait_for_prompt
      end
    end

    protected

    ##
    # This is the ass-hattery that we need to go
    # through in order to read from stderr and
    # stdout from a long-running process without
    # eternally blocking the parent - and providing
    # the ability to asynchronously write into the
    # input stream.
    #
    # If you know how to better do this accross
    # platforms (mac, win and nix) without losing
    # information (i.e. combining stderr and stdout
    # into a single stream), I'm all ears!
    def read_from pipe, to, until_prompt=nil
      line = ''
      lines = ''
      Thread.new do
        Thread.current.abort_on_exception = true
        while true do
          break if pipe.eof?
          char = pipe.readpartial 1
          line << char
          if char == "\n"
            to.puts line
            to.flush
            lines << line
            line = ''
          end
          if !until_prompt.nil? && line.match(until_prompt)
            lines << line
            to.printf line
            to.flush
            line = ''
            break
          end
        end
        lines
      end
    end

    def process_launched?
      @process_launched
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # create a 'task' instead of a 'file' task.
    #
    # @return [Rake::Task]
    def create_outer_task *args
      task *args do
        execute
      end
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # are NOT added to the CLEAN collection.
    # (Work performed in the Executable)
    #
    # @return [String]
    def update_rake_task_name_from_args *args
      self.rake_task_name = parse_rake_task_arg args.last
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # create the process in a thread 
    # in order to read and write to it.
    #
    # @return [Thread]
    def system_execute binary, params
      Sprout.current_system.execute_thread binary, params
    end

    private

    ##
    # Execute the collection of provided actions.
    def execute_actions
      action_stack.each do |action|
        break unless execute_action(action)
      end
      @action_stack = []
    end

    ##
    # Execute a single action.
    def execute_action action, silence=false
      action = action.strip
      Sprout.stdout.puts("#{action}\n") unless silence
      process_runner.puts action
      wait_for_prompt
    end

  end
end
