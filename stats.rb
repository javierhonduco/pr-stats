require 'octokit'

Thread.abort_on_exception = true

class PullRequestFetcher
  attr_accessor :stats, :total_prs

  def initialize(client, repo, state, max_pages = 1)
    @client = client
    @state = state
    @repo = repo
    @queue = Queue.new
    @max_pages = max_pages
    @total_prs = nil
    @stats = {}
  end

  def pull_requests(page = 1)
    @client.pull_requests(@repo, state: @state, page: page)
  end

  def process_prs(prs)
    prs.each do |pr|
      @stats[pr.id] = {
        state: pr.state,
        closed_at: pr.closed_at,
        created_at: pr.created_at,
        url: pr.url,
        merged_at: pr.merged_at,
        comments: pr.comments,
        additions: pr.additions,
        changed_files: pr.changed_files,
        author: pr.user.login,
      }
    end
  end

  def worker
    loop do
      page = @queue.pop
      return if page.nil?
      process_prs(pull_requests(page))
    end
  end

  def fetch
    fetch_first
    fetch_last_and_prepare
    start_workers
  end

  def start_workers
    Thread.new do
      worker
    end.join
  end

  def fetch_first
    process_prs(pull_requests)
  end

  def fetch_last_and_prepare
    hypermedia_last = @client.last_response.rels[:last]
    last_page_index = hypermedia_last.href.split('page=').last.to_i
    last_page = hypermedia_last.get.data
    @total_prs = 100 * (last_page_index - 1) + last_page.size
    enqueue_tasks(last_page_index)
  end

  def enqueue_tasks(last_page_index)
    pages = if @max_pages == -1
              last_page_index
            else
              @max_pages
            end
    2.upto(pages).each do |page|
      @queue << page
    end
    @queue << nil
  end
end

def main
  client = Octokit::Client.new(
    access_token: '7024115fe0421a5e95289da0cb79a5d17cda9c49',
    per_page: 10000
  )

  pr_fetcher = PullRequestFetcher.new(client, 'rails/rails', :closed)
  pr_fetcher.fetch
  stats = pr_fetcher.stats

  top_authors = stats.values.
    map { |v| v[:author] }.
    each_with_object(Hash.new(0)) { |user, hash| hash[user] +=1 }.
    sort_by(&:last).
    reverse
  open_close_difference = stats.values.
    select { |v| v[:state] == 'closed' }.
    map { |v| v[:closed_at] - v[:created_at] }.
    sort.
    reverse

  puts "Fetched #{stats.size} PRs"
  puts "Top 3 PR authors #{top_authors.take(3)}"
  puts "Smallest time-to-close #{open_close_difference.min}s"
  puts "Biggest time-to-close #{open_close_difference.max}s"
end

if $0 == __FILE__
  main
end
