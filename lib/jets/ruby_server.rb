require 'socket'
require 'json'
require 'stringio'

# https://ruby-doc.org/stdlib-2.3.0/libdoc/socket/rdoc/TCPServer.html
# https://stackoverflow.com/questions/806267/how-to-fire-and-forget-a-subprocess
#
# There's a generated bin/ruby_server which calls bin/ruby_server.rb as part of the
# starter project template. Usage:
#
#    bin/ruby_server # background
#    FOREGROUND=1 bin/ruby_server # foreground
#

# save copy of old stdout and stderr
$normal_stdout ||= $stdout
$normal_stderr ||= $stderr

module Jets
  class IO < StringIO
    def puts(text)
      $normal_stdout.puts(text) if ENV['JETS_DEBUG']
      super
    end
  end

  class RubyServer
    PORT = 8080

    def run
      $stdout.sync = true
      Jets::RubyServer.redirect_all_output
      Jets.boot # outside of child process for COW
      Jets.eager_load!

      # INT - ^C
      trap('INT') do
        puts "Shutting down ruby_server.rb..."
        sleep 0.1
        exit
      end
      if ENV['FOREGROUND'] # Usage above
        serve
        return
      end

      # Reaching here means we'll run the server in the background
      pid = Process.fork
      if pid.nil?
        serve
      else
        # parent process
        Process.detach(pid)
      end
    end

    def serve
      # child process
      server = TCPServer.new(8080) # Server bind to port 8080
      puts "Ruby server started on port #{PORT}" if ENV['FOREGROUND'] || ENV['JETS_DEBUG'] || ENV['C9_USER']
      input_completed = false
      loop do
        event, handler = nil, nil
        client = server.accept    # Wait for a client to connect
        unless input_completed
          event = client.gets.strip # text
          # puts event # uncomment for debugging, Jets has changed stdout to stderr
          handler = client.gets.strip # text
          # puts handler # uncomment for debugging, Jets has changed stdout to stderr
          input_completed = true
        end

        result = event['_prewarm'] ?
          prewarm_request(event) :
          standard_request(event, '{}', handler)

        Jets::RubyServer.write_output_log

        client.puts(result)
        client.close
        input_completed = false
      end
    end

    def prewarm_request(event)
      # JSON.dump("prewarmed_at" => Time.now.to_s)
      Jets.increase_prewarm_count
      %Q|{"prewarmed_at":"#{Time.now.to_s}"}| # raw json for speed
    end

    def standard_request(event, context, handler)
      Jets::Processors::MainProcessor.new(
        event,
        context,
        handler).run
    rescue Exception => e
      JSON.dump(
        "stackTrace" => e.backtrace,
        "errorMessage" => e.message,
        "errorType" => "RubyError",
      )
    end

    def self.run
      new.run
    end

    # Override for Lambda processing.
    # $stdout = $stderr might seem weird but we want puts to write to stderr which
    # is set in the node shim to write to stderr.  This directs the output to
    # Lambda logs.
    # Printing to stdout managles up the payload returned from Lambda function.
    # This is not desired when returning payload to API Gateway eventually.
    #
    # Additionally, set both $stdout and $stdout to a StringIO object as a buffer.
    # At the end of the request, write this buffer to the filesystem.
    # In the node shim, read it back and write it to AWS Lambda logs.
    def self.redirect_all_output
      # yes, we want to reset whats in $stdout every time this method gets called
      $stdout = $stderr = Jets::IO.new # reset $stdout
      $stdout.sync = true
      $stderr.sync = true
    end

    def self.write_output_log
      IO.write("/tmp/jets-output.log", $stdout.string)
      redirect_all_output
    end
  end
end

