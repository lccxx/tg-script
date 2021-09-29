#!/usr/bin/env ruby

require 'json'
require 'open3'

class Tg
  HOME = ENV['HOME'] || '/home/lich'
  CMD = "#{HOME}/.tmp/tg/bin/telegram-cli --json --disable-colors --disable-readline"
  MSGS_FILENAME = "#{HOME}/.tg-script-msgs.json"
  MAX_QUEUE_SIZE = 9999

  def initialize
    @stdin, @stdout, @stderr, @wait_thr = nil

    @stop = false

    @msgs = [ ]
    @last_extend = nil
    @extend_count = 0

    load_msgs
  end

  def load_msgs
    if File.exists? MSGS_FILENAME
      @msgs = JSON.parse File.read MSGS_FILENAME
    end
  end

  def save_msgs
    open(MSGS_FILENAME, 'wb') { |fo| fo.write @msgs.to_json }
  end

  def send(to, text)
    return if @stdin.nil? || @stop === true

    p msg = "msg #{to} #{text}\n"
    @stdin << msg
  end

  def process(msg)
    @msgs << msg if @msgs.find { |m| msg['id'] === m['id']  }.nil?
    @msgs.drop 1 if @msgs.size > MAX_QUEUE_SIZE
    save_msgs

    if 'message' === msg['event']
      stop if '/quit@lccxx' === msg['text']

      process_werewolf
    end
  end

  def process_werewolf
    extend_text = '/extend@werewolfbot 123'
    last_extend_index = -1
    last_extend_r_index = -1
    (0...@msgs.size).to_a.reverse.each { |i| msg = @msgs[i]
      break if /游戏取消/.match?(msg['text'])
      if msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
        if msg['media']  && 'unsupported' === msg['media']['type']
          last_extend_r_index = i
        end
      end
      break last_extend_index = i if extend_text === msg['text']
      break if /#players: (\d+)/.match?(msg['text'])
    }

    if last_extend_index != -1 && last_extend_r_index != -1
      delete_msg last_extend_r_index
      delete_msg last_extend_index
    end


    player_count = 0
    player_count_index = -1
    has_own = false
    (0...@msgs.size).to_a.reverse.each { |i| msg = @msgs[i]
      break if /游戏取消/.match?(msg['text'])
      if /在最近30秒内加入了游戏/.match?(msg['text'])
        player_count += msg['text'].scan(', ').count + 1
        has_own = /lccc/.match?(msg['text'])
      end
      last_extend_index = i if extend_text == msg['text']
      if /#players: (\d+)/.match?(msg['text'])
        break player_count_index = i
      end
    }

    puts "player_count: #{player_count}, player_count_index: #{player_count_index}, has_own: #{has_own}"

    (player_count_index...@msgs.size).to_a.reverse.each { |i| msg = @msgs[i]
      break if @last_extend && Time.now - @last_extend < [5, 99][@extend_count % 2]

      next if msg['from'] && 'Werewolf_Moderator' != msg['from']['print_name']

      if msg['media']  && 'unsupported' === msg['media']['type']
        send(msg['to']['print_name'], extend_text)
        @last_extend = Time.now
        @extend_count += 1
      end
    } if player_count < 5 && has_own && player_count_index != -1
  end

  def delete_msg(i)
    msg = @msgs.delete_at i
    @stdin << "delete_msg #{msg['id']}\n"
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
