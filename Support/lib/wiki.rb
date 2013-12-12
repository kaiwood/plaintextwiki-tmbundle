#!/usr/bin/env ruby
require 'fileutils'
require 'uri'

class PlainTextWiki
    # Default extension for page creation
    EXT = ".txt"
    EXPORT_FORMAT = "markdown" # "markdown" and "textile" are recognised
    EXPORT_EXT = ".html"

    # set by the initializer, passed in
    attr_reader :dir

    def initialize(dir)
        # Exit unless dir is set (usually from ENV['TM_DIRECTORY'])
        # The TextMate command will demand that the file is saved (and so the
        # directory will be set), but it's best to double check given the
        # failure mode
        unless dir
          puts "Save this file first."
          exit 206
        end

        @dir = dir
        @pages = nil
    end

    def follow_link
       if ENV['TM_SCOPE'].include?('meta.link.wiki.pagename.delimited')
          idx = ENV['TM_LINE_INDEX'].to_i
          pagename = (((ENV['TM_CURRENT_LINE'][0..idx-1] || "").reverse)[/^[^\[]*/] || "").reverse + ENV['TM_CURRENT_LINE'][idx..-1][/^[^\]]*/]
          pagename.tr("[]", "").capitalize!
        else
          pagename = ENV['TM_CURRENT_WORD']
        end
        go_to(pagename)
    end

    def go_to_index_page
        go_to("IndexPage")
    end

    def go_to(pagename)
      @dir = ENV['TM_PROJECT_DIRECTORY'] if is_absolute_link?(pagename)
      pagename = pagename.split('/').reject {|name| name.empty?}.join('/')
      existent = pages.detect {|p| p.downcase == pagename.downcase} # we need the filename with the correct case

      # Touch the file if it doesn't exist
      touch_file(dir, pagename) unless existent
      open_in_tm("#{dir}/#{existent || pagename}#{EXT}")
    end

    def touch_file(dir, pagename)
      FileUtils.mkdir_p(dir)
      FileUtils.touch("#{dir}/#{pagename}#{EXT}")
      refresh
    end

    # switch away from TextMate and back to refresh the project drawer
    def refresh
      `osascript -e 'tell application "Dock" to activate'; osascript -e 'tell application "TextMate" to activate'`
    end

    def open_in_tm(fn)
      `open "txmt://open/?url=file://#{URI.escape(fn, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))}"`
    end

    def linked_page_list
        pages.map { |p| "* [[#{p}]]" }.join("\n")
    end

    def export_as_html
      export_dir = ask_for_export_dir

      # For each file, HTML-ify the links, convert to HTML using Markdown, and save
      pages.each do |p|
        html = transform.call(with_html_links("#{dir}/#{p}#{EXT}", export_dir))
        fname = "#{export_dir}/#{p}#{EXPORT_EXT}"
        FileUtils.mkdir_p(File.dirname(fname))
        File.open(fname, 'w') do |f|
          f.puts(wiki_header % [p, export_dir])
          f.puts(html)
          f.puts(wiki_footer % [export_dir, Time.now.gmtime, ENV['TM_FULLNAME'] || ENV['USER']])
        end
      end

      # Copy the stylesheet over
      FileUtils.copy("#{wiki_styles_path}", "#{export_dir}/wiki-styles.css")

      # Open the exported wiki in the default HTML viewer
      `open #{export_dir}/IndexPage#{EXPORT_EXT}`
    end

    def ask_for_export_dir
      # dialogs
      cocoadialog = "'#{ENV['TM_SUPPORT_PATH']}/bin/CocoaDialog.app/Contents/MacOS/CocoaDialog'"
      export_dir_dialog = %Q[#{cocoadialog} fileselect --text "Choose a directory for wiki export" --select-only-directories]
      replace_dialog = %Q[#{cocoadialog} msgbox --text "Export will replace files" --icon "x" --informative-text "There are files in the way in the export directory. They will be lost if you continue." --button1 "Cancel Export" --button2 "Replace All"]

      # Ask the user for an export directory, exiting if cancelled
      export_dir = `#{export_dir_dialog}`.strip
      exit if export_dir.empty?

      # Make sure there are no files in the way
      obstructing = (pages + ["#{export_dir}/wiki-styles.css"]).any? {|f| File.file?("#{export_dir}/#{f}#{EXPORT_EXT}") }
      if obstructing && (`#{replace_dialog}`.to_i != 2)
        puts "Cancelled Export Wiki as HTML"
        exit 206
      end
      export_dir
    end

    def templates_dir
        "#{ENV['TM_BUNDLE_SUPPORT']}/templates"
    end

    def pages
        @pages ||= load_pages
    end

    def is_absolute_link?(pagename)
      pagename[0, 1] == '/'
    end

    def load_pages(path = nil)
      path ||= dir
      files = Dir.entries(path).reject {|fn| fn[0, 1] == '.'}
      files.inject([]) do |result, fn|
        if File.directory?("#{path}/#{fn}")
          result + load_pages("#{path}/#{fn}").map {|pagename| "#{fn}/#{pagename}"}
        elsif File.extname(fn) == EXT
          result + [get_pagename(fn)]
        else
          result
        end
      end.sort_by {|fn| fn.downcase}
    end

    def get_pagename(fn)
      fn[0..(fn.length-File.extname(fn).length-1)]
    end

    def wiki_header
        d = File.file?("#{dir}/wiki-header.html") ? dir : templates_dir
        open("#{d}/wiki-header.html", "r").read
    end

    def wiki_footer
        d = File.file?("#{dir}/wiki-footer.html") ? dir : templates_dir
        open("#{d}/wiki-footer.html", "r").read
    end

    def wiki_styles_path
        d = File.file?("#{dir}/wiki-styles.css") ? dir : templates_dir
        "#{d}/wiki-styles.css"
    end

    def with_html_links(filename, export_dir)
        # This match recognises HTML links, and delimited then camelcase pagenames. Each is treated differently
        open(filename, 'r').read.gsub(
            / (<a .+?<\/a>) # 1, HTML capture
            | ((http:\/\/.+?)(\s$)) # 2, 3, 4 http construct
            | (\[\[(.+?)\]\]) # 5, 6, delimited capture
            | (\b([A-Z][a-z]+([A-Z][a-z]*)+)\b) # 7 camelcase
            /x ) do |m|
            if $1
                $1
            elsif $3
                %Q[<a href="#{URI.escape($3)}">#{URI.escape($3)}</a>#{$4}]
            else
                pagename = $6 ? $6.tr("[]", "") : $7
                if (!pages.include?(pagename)) and (pages.map { |p| p.downcase }.include? pagename.downcase)
                    pagename = pages.select { |p| p.downcase == pagename.downcase }.first
                end
                %Q[<a href="#{export_dir}#{link(pagename, filename)}#{EXPORT_EXT}">#{pagename}</a>]
            end
        end
    end

    def link(pagename, filename)
      is_absolute_link?(pagename) ? pagename : "#{File.dirname(filename).gsub(dir, '')}/#{pagename}"
    end

    def transform
      return @transform if @transform
      case EXPORT_FORMAT
        when "markdown"
          puts "opsops"
          require "#{ENV['TM_SUPPORT_PATH']}/lib/bluecloth.rb"
          require "#{ENV['TM_SUPPORT_PATH']}/lib/rubypants.rb"
          @transform = Proc.new { |s| RubyPants.new(BlueCloth.new(s).to_html).to_html }
        when "textile"
          require "#{ENV['TM_SUPPORT_PATH']}/lib/redcloth.rb"
          @transform = Proc.new { |s| RedCloth.new(s).to_html }
      end
    end

    def self.create_new_wiki
        # Ask the user for a new wiki directory, exiting if cancelled
        cocoadialog = "#{ENV['TM_SUPPORT_PATH']}/bin/CocoaDialog.app/Contents/MacOS/CocoaDialog"
        dir = `'#{cocoadialog}' fileselect --text "Choose a directory for your new wiki (IndexPage.txt will be created automatically)" --select-only-directories`.strip
        exit if dir.empty?

        # Exit if IndexPage.txt already exists
        if File.file?("#{dir}/IndexPage.txt")
          puts "IndexPage.txt already exists here"
          exit 206
        end

        # Create and populate the index page by copying it from templates
        wiki = PlainTextWiki.new(dir)
        FileUtils.copy("#{wiki.templates_dir}/IndexPage.txt", "#{wiki.dir}/IndexPage.txt")

        # Open this wiki in a project window
        `open -a TextMate "#{dir}"`

        # Select the index page
        wiki.go_to_index_page
    end
end
