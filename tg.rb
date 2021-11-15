#!/usr/bin/env ruby

require 'json'
require 'open3'

class Tg
  PROJECT_HOME = ENV['PROJECT_HOME'] || File.dirname(__FILE__)
  TELEGRAM_CLI = "#{PROJECT_HOME}/../tg/bin/telegram-cli"
  TELEGRAM_CLI_OPTIONS = '--json --disable-colors --disable-readline'
  MSGS_FILENAME = "#{PROJECT_HOME}/msgs.json"
  LOG_FILENAME = "#{PROJECT_HOME}/run.log"
  MAX_QUEUE_SIZE = 9999

  STICKER_START = '0500000080b97056c5020000000000004b04bccd8bf722a0'

  def initialize
    @stdin, @stdout, @stderr, @wait_thr = nil

    @stop = false

    @groups = {  }  # message groups, msgs
    @last_extend = Time.at 0
    @extend_count = 0

    @last_msg_at = nil

    load_msgs
  end

  def load_msgs
    if File.exists? MSGS_FILENAME
      @groups = JSON.parse File.read MSGS_FILENAME
    end
  end

  def save_msgs
    File.write(MSGS_FILENAME, @groups.to_json, mode: 'wb')
  end
  
  def log(text)
    File.write(LOG_FILENAME, text, mode: 'a')
  end

  def send_msg(group, text)
    return if @stdin.nil? || @stop === true

    @stdin << msg = "msg #{group} #{text}\n"

    log "send #{msg}"
  end

  def process(msg)
    if 'message' === msg['event'] && msg['to'] && msg['to']['print_name']
      group = msg['to']['print_name']
      msgs = @groups[group] || [ ]

      msgs << msg if msgs.find { |m| msg['id'] === m['id'] }.nil?
      msgs.drop 1 if msgs.size > MAX_QUEUE_SIZE

      if msgs.find { |m|
          m['from'] && 'Werewolf_Moderator' === m['from']['print_name'] && m['to'] && m['to']['peer_type'] != 'user' }

        process_werewolf group, msgs
      else
        msgs.clear
      end

      @groups[group] = msgs
      save_msgs
    end
  end

  def process_werewolf(group, msgs)
    start_reg = /^游戏启动中/
    own_reg = /lccc/
    player_count_reg = /#players: (\d+)/
    player_count_r_reg = /在最近30秒内加入了游戏/
    player_count_f_reg = /还剩 (\d+) 名玩家。/
    cancel_reg = /游戏取消/

    extend_text = '/extend@werewolfbot 123'
    last_extend_index = -1
    last_extend_r_index = -1
    (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      break if cancel_reg.match?(msg['text'])
      if msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
        if msg['media']  && 'unsupported' === msg['media']['type']
          last_extend_r_index = i
        end
      end
      break last_extend_index = i if extend_text === msg['text']
      break if player_count_reg.match?(msg['text'])
      break if start_reg.match?(msg['text'])
    }

    if last_extend_index != -1 && last_extend_r_index != -1
      r_msg = msgs[last_extend_r_index]
      e_msg = msgs[last_extend_index]
      if Time.at(r_msg['date'].to_i) - Time.at(e_msg['date'].to_i) < 19
        delete_msg msgs, last_extend_r_index

        (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
          if msg && extend_text === msg['text']
            delete_msg msgs, i

            msg = msgs[i - 1]
            if msg && msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
              if msg['media'] && 'unsupported' === msg['media']['type']
                delete_msg msgs, i - 1
              end
            end
          end
        }
      end
    end

    player_count = 0
    player_count_index = -1
    has_own = false
    (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      break if cancel_reg.match?(msg['text'])
      if player_count_r_reg.match?(msg['text'])
        player_count += msg['text'].scan(', ').count + 1
        has_own = own_reg.match?(msg['text']) if not has_own
      end
      last_extend_index = i if extend_text == msg['text']
      if player_count_reg.match?(msg['text'])
        break player_count_index = i
      end
      break if start_reg.match?(msg['text'])
    }
    
    player_count_f_index = -1
    (player_count_index...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      rs = player_count_f_reg.match(msg['text'])
      if rs && rs.size === 2
        player_count = rs[1].to_i
        break player_count_f_index = i
      end
    } if player_count_index != -1
    
    (player_count_f_index...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      if player_count_r_reg.match?(msg['text'])
        player_count += msg['text'].scan(', ').count + 1
      end
    } if player_count_f_index != -1

    msg = msgs.last

    log "#{group}, player_count: #{player_count}, has_own: #{has_own}, extend_count: #{@extend_count}\n"

    if player_count < 5 && has_own && player_count_index != -1
      if Time.now - @last_extend > [9, 5][@extend_count % 2]
        if msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
          if msg['media'] && 'unsupported' === msg['media']['type']
            send_msg(group, extend_text)
            @last_extend = Time.now
            @extend_count += 1
          end
        end
      end
    end

    if player_count_index != -1
      (0...player_count_index).to_a.reverse.each { |i| msgs.delete_at i }
    end

    if start_reg.match?(msg['text'])
      @stdin << "fwd #{msg['to']['print_name']} #{STICKER_START}\n"
    end
  end

  def delete_msg(msgs, i)
    msg = msgs.delete_at i
    @stdin << "delete_msg #{msg['id']}\n"
  end

  def check
    stop if Time.now - @last_msg_at > 39

    @stdin << "get_self\n"
  end

  def stop
    @stdin << "quit\n"
    @stop = true
  end

  def start
    `pkill telegram-cli`

    cmd = TELEGRAM_CLI
    cmd = 'telegram-cli' if not File.exists?(TELEGRAM_CLI)
    cmd = "#{cmd} #{TELEGRAM_CLI_OPTIONS}"

    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3 cmd

    trap("SIGINT") { stop }
    trap("TERM") { stop }

    Thread.new { loop {
      break if @stop

      sleep 29
      check
    } }

    loop {
      break if @stop

      line = @stdout.gets.strip
      @last_msg_at = Time.now

      begin

        process JSON.parse line

      rescue JSON::ParserError
        # do nothing
      ensure
        log "#{line}\n"
      end
    }

    @stdin.close
    @stdout.close
    @stderr.close
  end
end


Tg.new.start if __FILE__ == $0
