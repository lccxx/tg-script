#!/usr/bin/env ruby

require 'json'
require 'open3'

class Tg
  CMD = '/home/lich/.tmp/tg/bin/telegram-cli --json --disable-colors --disable-readline'
  MAX_QUEUE_SIZE = 9999

  def initialize
    @stdin, @stdout, @stderr, @wait_thr = nil

    @stop = false

    @msgs = [ ]
    @last_extend = nil
    @extend_count = 0
  end

  def send(to, text)
    return if @stdin.nil? || @stop === true

    p msg = "msg #{to} #{text}\n"
    @stdin << msg
  end

  def process(msg)
    @msgs << msg
    @msgs.drop 1 if @msgs.size > MAX_QUEUE_SIZE

    if 'message' === msg['event']
      stop if '/quit@lccxx' === msg['text']

      process_werewolf
    end
  end

  def process_werewolf
    player_count = 0
    player_count_index = -1
    has_own = false
    (0...@msgs.size).to_a.reverse.each { |i| msg = @msgs[i]
      break if /游戏取消/.match?(msg['text'])
      if /在最近30秒内加入了游戏/.match?(msg['text'])
        player_count += msg['text'].scan(', ').count + 1
        has_own = /lccc/.match?(msg['text'])
      end
      if /#players: (\d+)/.match?(msg['text'])
        break player_count_index = i
      end
    }

    puts "player_count: #{player_count}, player_count_index: #{player_count_index}, has_own: #{has_own}"

    (0..player_count_index).to_a.reverse.each { |i| msg = @msgs[i]
      break if @last_extend && Time.now - @last_extend < [5, 99][@extend_count % 2]

      next if 'Werewolf_Moderator' != msg['from']['print_name']

      if msg['media']  && 'unsupported' === msg['media']['type']
        send(msg['to']['print_name'], '/extend@werewolfbot 123')
        @last_extend = Time.now
        @extend_count += 1
      end
    } if player_count < 5 && has_own
  end

  def stop
    @stdin << "quit\n"
    @stop = true
  end

  def start
    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3 CMD

    trap("SIGINT") { stop }
    trap("TERM") { stop }

    loop {
      break if @stop

      puts line = @stdout.gets.strip

      begin

        process JSON.parse line

      rescue JSON::ParserError
        # do nothing
      end
    }

    @stdin.close
    @stdout.close
    @stderr.close
  end
end


Tg.new.start
