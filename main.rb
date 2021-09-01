require 'utils'
require 'nokogiri'

module Cmds
  URL = "https://support.microsoft.com/en-us/windows/wallpapers-5cfa0cc7-b75a-165a-467b-c95abaf5dc2a"

  def self.cmd_dl(dest_dir: "out")
    log = Utils::Log.new level: ENV["DEBUG"] == "1" ? :debug : :info
    Scraper.new(URL, dest_dir, log: log).scrape
  end
end

class Scraper
  def initialize(url, dest_dir, log:)
    @url = url
    @dest_dir = Pathname dest_dir
    @log = log
  end

  def scrape
    doc = Nokogiri::HTML.parse \
      Utils::SimpleHTTP.new(@url, log: @log["http"]).get("").body

    cats = {}
    doc.
      css("#ID0EBD-supTabControlContent-1 .ocpSection[aria-label]").
      each { |el| (title, links = scrape_cat_el el) and cats[title] = links }

    q = Queue.new
    thrs = Array.new 4 do
      Thread.new do
        Thread.current.abort_on_exception = true
        while job = q.shift do job.() end
      end
    end

    count = 0
    cats.each do |title, links|
      dir = @dest_dir.join title
      dir.mkdir unless dir.directory?
      links.each do |l|
        q << -> {
          Downloader.new(dir, l, log: @log["#{title}/#{l.title}"]).download
        }
      end
      @log[title].info "enqueued #{links.size} download jobs"
    end
    q.close
    thrs.each &:join
  end

  private def scrape_cat_el(el)
    title = (el["aria-label"] or raise "missing category label").strip
    links = el.css("a").map do |a|
      link = ImageLink.new
      link.uri = URI((a["href"] or raise "missing image link href"))
      link.title = (a.text[/Get (.+?) *wallpaper/i, 1] || a.text).strip.
        tap { |s| s =~ /\w/ or raise "invalid image title: #{s.inspect}" }
      link
    end
    if links.empty?
      return if title.empty?
      raise "category with no images"
    end
    [title, links]
  end
end

ImageLink = Struct.new :title, :uri do
  def image_id
    uri.path[%r[/asset-blobs/(\d+?)_], 1] or raise "image ID not found in URL"
  end
end

class Downloader
  def initialize(dest_dir, link, log:)
    @dest_dir = dest_dir
    @link = link
    @log = log
  end

  def download
    if downloaded_file
      @log.debug "already downloaded"
      return
    end
    http = Utils::SimpleHTTP.new @link.uri, log: @log["http"], yield_resp: true
    written = 0
    http.get "" do |resp|
      resp['content-type'] =~ /^image\/(\w+)/i \
        or raise "image content-type not found"
      ext = $1.downcase
      out, tmp = "#{@link.title} - #{@link.image_id}.#{ext}".then do |filename|
        [ @dest_dir.join(filename),
          @dest_dir.join(filename + TMP_EXTNAME) ]
      end
      tmp.open 'w' do |f|
        @log[dest: f.path].info "downloading"
        resp.read_body do |chunk|
          f.write chunk
          written += chunk.bytesize
        end
      end
      File.rename tmp, out
    end
    @log.info "downloaded #{Utils::Fmt.size written}"
  end

  TMP_EXTNAME = ".tmp"

  private def downloaded_file
    @dest_dir.glob("* - #{@link.image_id}.*").
      reject { |f| f.extname == TMP_EXTNAME }.
      first
  end
end

if $0 == __FILE__
  require 'metacli'
  MetaCLI.new(ARGV).run Cmds
end
