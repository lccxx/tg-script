#!/usr/bin/env ruby

require 'json'
require 'open3'
require 'net/http'
require 'nokogiri'

class Tg
  PROJECT_HOME = ENV['PROJECT_HOME'] || File.dirname(__FILE__)
  TELEGRAM_CLI = "#{PROJECT_HOME}/../tg/bin/telegram-cli"
  TELEGRAM_CLI_OPTIONS = '--json --disable-colors --disable-readline'
  MSGS_FILENAME = "#{PROJECT_HOME}/msgs.json"
  LOG_FILENAME = "#{PROJECT_HOME}/run.log"
  MAX_QUEUE_SIZE = 9999

  EXTEND_TIME = 123
  EXTEND_TEXT = "/extend@werewolfbot #{EXTEND_TIME}"

  STICKERS_BYE = [ '0500000080b97056fb020000000000004b04bccd8bf722a0' ]

  STICKERS_GOOD = [ '0500000080b97056dc020000000000004b04bccd8bf722a0',
                   '0500000080b97056df020000000000004b04bccd8bf722a0',
                   '0500000080b97056e1020000000000004b04bccd8bf722a0',
                   '0500000080b97056e2020000000000004b04bccd8bf722a0',
                   '05000000ab7a7b41b2a527000000000040b8d736b133cd23' ]

  STICKERS_START = [ '0500000080b97056e0020000000000004b04bccd8bf722a0',
                    '0500000080b97056c5020000000000004b04bccd8bf722a0' ]

  WIKI_API_PREFIX = 'https://en.wikipedia.org/w/api.php?'


  def initialize
    @stdin, @stdout, @stderr, @wait_thr = nil

    @stop = false

    @groups = {  }  # message groups, msgs

    @logs_queue = [ ]
    @tasks_queue = { }
    @tasks_counter = 0

    @last_msg_at = nil
    @last_extend_at = { }
    @extend_count = { }
    @need_extend = { }

    @save_flag = false
  end

  def log(text)
    @logs_queue << "#{Time.now}: #{text.strip}\n"
  end

  def send_msg(group, text)
    return if @stdin.nil? || @stop === true

    @stdin << msg = "msg #{group} #{text}\n"
    log "send #{msg}"
  end

  def process(msg)
    if 'message' === msg['event'] && msg['from'] && msg['to'] && msg['to']['print_name']
      group = msg['to']['print_name']
      msgs = @groups[group] || [ ]

      return if msgs.find { |m| msg['id'] === m['id'] }

      msgs << msg
      msgs.drop 1 if msgs.size > MAX_QUEUE_SIZE

      1.times {
        break if process_quit(group)

        break if process_ping(group)

        break if process_werewolf(group)

        break if process_wiki(group)

        msgs.clear
      }

      @groups[group] = msgs
      @save_flag = true
    end
  end

  def process_quit(group)
    msgs = @groups[group]

    if msgs.last['text'] === '/start@lccxz'
      @stdin << "fwd #{group} #{rand_select STICKERS_GOOD}\n"
    end
    if msgs.last['text'] === '/quit@lccxz'
      @stdin << "fwd #{group} #{rand_select STICKERS_BYE}\n"
    end

    (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      return false if msg['text'] === '/start@lccxz'
      return true if msg['text'] === '/quit@lccxz'
    }
    return false
  end

  def process_ping(group)
    msg = @groups[group].last if @groups[group]

    if msg && msg['text'] === '/ping@lccxz'
      @stdin << "fwd #{group} #{rand_select STICKERS_GOOD}\n"
    end
  end

  def send_extend(group)
    return if process_quit(group)

    send_msg(group, EXTEND_TEXT)
    @last_extend_at[group] = Time.now
    @extend_count[group] = @extend_count[group] ? @extend_count[group] + 1 : 1

    @tasks_queue[5 + @tasks_counter] = proc {  # check & send again after 5 seconds
      msgs = @groups[group]
      flag = false
      (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
        if EXTEND_TEXT === msg['text']
          flag = true
          break send_extend(group)
        end
      }
      @extend_count[group] = 0 if not flag
    } if @extend_count[group] <= 5
  end

  def process_werewolf(group)
    msgs = @groups[group]

    return false if not msgs.find { |m|
      'Werewolf_Moderator' === m['from']['print_name'] && m['to']['peer_type'] != 'user'
    }

    start_reg = /^游戏启动中/
    own_reg = /lccc/
    player_count_reg = /#players: (\d+)/
    player_count_r_reg = /在最近30秒内加入了游戏/
    player_count_f_reg = /还剩 (\d+) 名玩家。/
    cancel_reg = /游戏取消/

    extend_count = 0
    last_extend_at = Time.at(0)
    last_extend_index = -1
    last_extend_r_index = -1
    (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
      break if cancel_reg.match?(msg['text'])
      if msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
        if msg['media']  && 'unsupported' === msg['media']['type']
          last_extend_r_index = i
        end
      end
      if EXTEND_TEXT === msg['text']
        extend_count += 1
        last_extend_at = Time.at(msg['date'].to_i) if last_extend_at == Time.at(0)
        break last_extend_index = i
      end
      break if player_count_reg.match?(msg['text'])
      break if start_reg.match?(msg['text'])
    }

    if last_extend_index != -1 && last_extend_r_index != -1
      r_msg = msgs[last_extend_r_index]
      e_msg = msgs[last_extend_index]
      if Time.at(r_msg['date'].to_i) - Time.at(e_msg['date'].to_i) < 19
        delete_msg msgs, last_extend_r_index

        (0...msgs.size).to_a.reverse.each { |i| msg = msgs[i]
          if msg && EXTEND_TEXT === msg['text']
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
      last_extend_index = i if EXTEND_TEXT == msg['text']
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

    log "#{group}, player_count: #{player_count}, has_own: #{has_own}, extend_count: #{extend_count}"

    if player_count < 5 && has_own && player_count_index != -1
      @need_extend[group] = true
      if Time.now - last_extend_at > [9, 5][extend_count % 2]
        if msg['from'] && 'Werewolf_Moderator' === msg['from']['print_name']
          if msg['media'] && 'unsupported' === msg['media']['type']
            send_extend group
          end
        end
      end
    else
      @need_extend[group] = false
    end

    if player_count_index != -1
      (0...player_count_index).to_a.reverse.each { |i| msgs.delete_at i }
    end

    # starting message
    if player_count_reg.match?(msg['text'])
      @last_extend_at[group] = Time.now
    end

    # started message
    if start_reg.match?(msg['text'])
      @stdin << "fwd #{group} #{rand_select STICKERS_START}\n"
    end

    return true
  end

  def process_wiki(group)
    msg = @groups[group].last if @groups[group]
    title = msg['text'][/^\/wiki@lccxz(.*)/, 1] if msg && msg['text']
    return false if title.nil?

    title = title.strip
    if title.length == 0
      params = { action: 'query', list: 'random', rnnamespace: 0, format: 'json' }
      res = JSON.parse Net::HTTP.get URI "#{WIKI_API_PREFIX}#{URI.encode_www_form params}"
      title = res['query']['random'].first['title']
    end
 
    params = { action: 'parse', page: title, format: 'json' }
    res = JSON.parse Net::HTTP.get URI "#{WIKI_API_PREFIX}#{URI.encode_www_form params}"
    tmp_text_file = "/tmp/tg-send-file-#{Time.now.to_f}.txt"
    doc = Nokogiri::HTML(res['parse']['text']['*'])
    text = doc.css('p').text[/.*is.*\./]
    text = doc.css('p').text[/.*was.*\./] if text.nil?
    text = doc.text if text.nil?
    text = text.gsub(/\[\d+\]/, '') if text
    text = "#{text[0..4091]} ..." if text.length > 4096
    File.write(tmp_text_file, text)
    @stdin << "send_text #{group} #{tmp_text_file}\n"
    @tasks_queue[@tasks_counter] = proc { File.delete tmp_text_file }
    return true
  rescue e
  end

  def delete_msg(msgs, i)
    msg = msgs.delete_at i
    @stdin << "delete_msg #{msg['id']}\n"
  end

  def rand_select(arr)
    arr[(rand * arr.size).to_i]
  end

  def check
    stop if Time.now - @last_msg_at > 39

    @stdin << "get_self\n"

    @tasks_queue[29 + @tasks_counter] = proc { check }
  end

  def stop
    # quit after 1 second
    @tasks_queue[1 + @tasks_counter] = proc {
      begin; @stdin << "quit\n"; rescue; end
      @stop = true
    }
  end

  def start
    `pkill telegram-cli`

    trap("SIGINT") { stop }
    trap("TERM") { stop }

    if File.exists? MSGS_FILENAME
      @groups = JSON.parse File.read MSGS_FILENAME
    end

    Thread.new { loop { begin # tasks loop
      break if @stop

      @tasks_queue[@tasks_counter].call if @tasks_queue[@tasks_counter]
      @tasks_counter += 1

      if @save_flag
        File.write(MSGS_FILENAME, @groups.to_json, mode: 'wb')
        @save_flag = false
      end

      open(LOG_FILENAME, 'a') { |fo|
        @logs_queue.each { |log|
          fo.write log
        }
        @logs_queue.clear
      } if not @logs_queue.empty?

      @need_extend.keys.each { |group|
        if @need_extend[group] && @last_extend_at[group] && Time.now - @last_extend_at[group] > EXTEND_TIME
          send_extend group
        end
      }

    rescue e
      log "#{e}"
    ensure
      sleep 1
    end } }

    @tasks_queue[29] = proc { check }


    cmd = TELEGRAM_CLI
    cmd = 'telegram-cli' if not File.exists?(TELEGRAM_CLI)
    cmd = "#{cmd} #{TELEGRAM_CLI_OPTIONS}"

    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3 cmd
    loop {
      break if @stop

      line = @stdout.gets
      next sleep 1 if line.nil?

      @last_msg_at = Time.now

      log line
      begin

        process JSON.parse line

      rescue JSON::ParserError
        # do nothing
      end
    }

    log 'QUIT'
    @stdin.close
    @stdout.close
    @stderr.close
  end
end


Tg.new.start if __FILE__ == $0
