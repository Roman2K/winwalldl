require 'utils'
require 'nokogiri'

module Cmds
  URL = "https://support.microsoft.com/en-us/windows/wallpapers-5cfa0cc7-b75a-165a-467b-c95abaf5dc2a"

  def self.cmd_dl(dest_dir: "out", cat_dirs: true)
    log = Utils::Log.new level: ENV["DEBUG"] == "1" ? :debug : :info
    filetree_t = cat_dirs ? Filetree::CatDirs : Filetree::Flat
    Scraper.new(URL, dest_dir, filetree_t, log: log).scrape
  end
end

class Scraper
  def initialize(url, dest_dir, filetree_t, log:)
    @url = url
    @dest_dir = Pathname dest_dir
    @filetree_t = filetree_t
    @log = log
  end

  def scrape
    doc = Nokogiri::HTML.parse \
      Utils::SimpleHTTP.new(@url, log: @log["http"]).get("").body

    cats = {}
    doc.
      css("#ID0EBD-supTabControlContent-1 .ocpSection[aria-label]").
      each { |el| (title, links = scrape_cat_el el) and cats[title] = links }
    cats.size >= 3 or raise "too few categories found"

    q = Queue.new
    thrs = Array.new 4 do
      Thread.new do
        Thread.current.abort_on_exception = true
        while job = q.shift do job.() end
      end
    end

    cats.each do |title, links|
      filetree = @filetree_t.new title
      dir = filetree.parent_dir(@dest_dir)
      dir.mkdir if dir != @dest_dir && !dir.directory?
      links.each do |l|
        q << -> {
          d = Downloader.new dir, l, filetree: filetree,
            log: @log["#{title}/#{l.title}"]
          d.download
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
  def initialize(dest_dir, link, filetree:, log:)
    @dest_dir = dest_dir
    @link = link
    @filetree = filetree
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
        or raise "response is not an image"
      ext = $1.downcase
      out, tmp = "#{@link.title} - #{@link.image_id}.#{ext}".then do |filename|
        filename = @filetree.basename filename
        [ @dest_dir.join(filename),
          @dest_dir.join(filename + TMP_EXTNAME) ]
      end
      tmp.open 'wb' do |f|
        @log[dest: f.path].info "downloading"
        resp.read_body do |chunk|
          written += f.write chunk
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

module Filetree
  class Basic
    def initialize(cat_title)
      @cat_title = cat_title
    end
  end
  class Flat < Basic
    def parent_dir(root); root end
    def basename(filename); "#{@cat_title} - #{filename}" end
  end
  class CatDirs < Basic
    def parent_dir(root); root.join @cat_title end
    def basename(filename); filename end
  end
end

if $0 == __FILE__
  require 'metacli'
  MetaCLI.new(ARGV).run Cmds
end
