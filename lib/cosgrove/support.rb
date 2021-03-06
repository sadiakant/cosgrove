module Cosgrove
  module Support
    include Utils
    include ActionView::Helpers::TextHelper
    include ActionView::Helpers::DateHelper
    
    def suggest_account_name(account_name)
      regex = /.*#{account_name.chars.each.map { |c| c }.join('.*')}.*/
      guesses = SteemData::Account.where(name: regex).distinct(:name)
      
      if guesses.any?
        guesses.sample
      end
    end

    def unknown_account(account_name, event = nil)
      help = ["Unknown account: *#{account_name}*"]
      event.channel.start_typing if !!event
      guess = suggest_account_name(account_name)

      help << ", did you mean: #{guess}?" if !!guess
      
      if !!event
        event.respond help.join
        return
      end
      
      help.join
    end
    
    def mongo_behind_warning(event)
      elapse = -1
      
      begin
        message = []
        
        if (blocks = head_block_number(:steem) - steem_data_head_block_number) > 1200
          elapse = blocks * 3
          message << "Mongo is behind by #{time_ago_in_words(elapse.seconds.ago)}."
        else
          0
        end
        
        if message.size > 0
          event.respond message.join(' ')
        end
      rescue => e
        event.respond "Mongo might be behind, but the API is also acting up.  Please try again later.\n\n```#{e.inspect}\n```"
        sleep 15
        event.respond Cosgrove::SnarkCommands::WITTY.sample
      end
      
      elapse
    end
    
    def cannot_find_input(event, message_prefix = "Unable to find that.")
      message = [message_prefix]
      
      message << if (blocks = head_block_number(:steem) - steem_data_head_block_number) > 86400
        elapse = blocks * 3
        "  Mongo is behind by #{time_ago_in_words(elapse.seconds.ago)}.  Try again later."
      else
        "  Mongo might be behind or this is not a valid input."
      end
        
      event.respond message.join(' ')
    end
    
    def append_link_details(event, slug)
      author_name, permlink = parse_slug slug
      created = nil
      cashout_time = nil
      
      if slug =~ /steemit.com/
        chain = :steem
      elsif slug =~ /golos.io/
        chain = :golos
      elsif slug =~ /golos.blog/
        chain = :golos
      else
        return # silntlly ignore this slug
      end
      
      post = case chain
      when :steem then SteemData::Post.where(author: author_name, permlink: permlink).last
      when :golos then GolosCloud::Comment.where(author: author_name, permlink: permlink).last
      end
      
      if post.nil?
        # Fall back to RPC
        api(chain).get_content(author_name, permlink) do |content, errors|
          unless content.author.empty?
            created = Time.parse(content.created + 'Z')
            cashout_time = Time.parse(content.cashout_time + 'Z')
          end
        end
      end
      
      return if post.nil?
      
      created ||= post.created
      cashout_time ||= post.cashout_time
      
      details = []
      age = time_ago_in_words(created)
      age = age.slice(0, 1).capitalize + age.slice(1..-1)
      
      details << if created < 30.minutes.ago
        "#{age} old"
      else
        "**#{age}** old"
      end
      
      if post.active_votes.any?
        upvotes = post.active_votes.map{ |v| v if v['percent'] > 0 }.compact.count
        downvotes = post.active_votes.map{ |v| v if v['percent'] < 0 }.compact.count
        netvotes = upvotes - downvotes
        details << "Net votes: #{netvotes}"
        
        # Only append this detail of the post less than an hour old.
        if created > 1.hour.ago
          votes = case chain
          when :steem then SteemData::AccountOperation.type('vote').starting(post.created)
          when :golos then GolosCloud::Vote.where('timestamp > ?', post.created)
          end
          total_votes = votes.count
          total_voters = votes.distinct(:voter).size
            
          if total_votes > 0 && total_voters > 0
            details << "Out of #{pluralize(total_votes - netvotes, 'vote')} cast by #{pluralize(total_voters, 'voter')}"
          end
        end
      end
      
      details << "Comments: #{post.children.to_i}"
      
      page_views = page_views("/#{post.parent_permlink}/@#{post.author}/#{post.permlink}")
      details << "Views: #{page_views}" if !!page_views
      
      begin
        event.respond details.join('; ')
      rescue Discordrb::Errors::NoPermission => _
        puts "Unable to append link details on #{event.channel.server.name} in #{event.channel.name}"
      end
      
      return nil
    end
    
    def find_account(key, event = nil, chain = :steem)
      key = key.to_s.downcase
      chain = chain.to_sym
      
      raise "Required argument: chain" if chain.nil?
      
      if chain == :steem
        account = if (accounts = SteemData::Account.where(name: key)).any?
          accounts.first
        end
      end
      
      if account.nil?
        account = if !!(cb_account = Cosgrove::Account.find_by_discord_id(key, chain))
          cb_account.chain_account
        end
      end
      
      if account.nil?
        account = if !!key
          if chain == :steem && (accounts = SteemApi::Account.where(name: key)).any?
            accounts.first
          elsif chain == :golos && (accounts = GolosCloud::Account.where(name: key)).any?
            accounts.first
          else
            # Fall back to RPC
            api(chain).get_accounts([key]) do |_accounts, errors|
              _accounts.first
            end
          end
        end
      end
        
      if account.nil?
        unknown_account(key, event)
      else
        account
      end
    end
    
    def page_views(uri)
      begin
        @agent ||= Cosgrove::Agent.new
        page = @agent.get("https://steemit.com#{uri}")
        
        _uri = URI.parse('https://steemit.com/api/v1/page_view')
        https = Net::HTTP.new(_uri.host,_uri.port)
        https.use_ssl = true
        request = Net::HTTP::Post.new(_uri.path)
        request.initialize_http_header({
          'Cookie' => @agent.cookies.join('; '),
          'accept' => 'application/json',
          'Accept-Encoding' => 'gzip, deflate, br',
          'Accept-Language' => 'en-US,en;q=0.8',
          'Connection' => 'keep-alive',
          'content-type' => 'text/plain;charset=UTF-8',
          'Host' => 'steemit.com',
          'Origin' => 'https://steemit.com'
        })
        
        csrf = page.parser.to_html.split(',"csrf":"').last.split('","new_visit":').first
        # Uncomment in case views stop showing.
        # puts "DEBUG: #{csrf}"
        return unless csrf.size == 36
        
        post_data = {
          csrf: csrf,
          page: uri
        }
        request.set_form_data(post_data)
        response = https.request(request)
        JSON[response.body]['views']
      rescue => e
        puts "Attempting to get page_view failed: #{e}"
      end
    end
    
    def last_irreversible_block(chain = :steem)
      seconds_ago = (head_block_number(chain) - last_irreversible_block_num(chain)) * 3
      
      "Last Irreversible Block was #{time_ago_in_words(seconds_ago.seconds.ago)} ago."
    end
    
    def send_url(event, url)
      open(url) do |f|
        tempfile = Tempfile.new(['send_url', ".#{url.split('.').last}"])
        tempfile.binmode
        tempfile.write(f.read)
        tempfile.close
        event.send_file File.open tempfile.path
      end
    end
    
    def muted(options = {})
      [] if options.empty?
      by = [options[:by]].flatten
      chain = options[:chain]
      muted = []
      
      by.each do |a|
        ignoring = []
        count = -1
        until count == ignoring.size
          count = ignoring.size
          follow_api(chain).get_following(a, ignoring.last, 'ignore', 100) do |ignores, errors|
            next unless defined? ignores.following
            
            ignoring += ignores.map(&:following)
            ignoring = ignoring.uniq
          end
        end
        muted += ignoring
      end
      
      muted.uniq
    end
  end
end
