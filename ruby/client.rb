#!/bin/ruby

# Haikeuken buildslave script
##############################################
# Copyright 2014 - 2015 Alexander von Gluck IV
# Released under the terms of the GPLv3
##############################################

@version = "0.2"
@rest_period = 10.0

gem 'git'

##########################################
# Requirements
##########################################
require 'json'
require 'net/http'
require 'yaml'
require 'git'
require 'open3'
require 'thread'

require 'pp'
##########################################

class String
def black;          "\033[30m#{self}\033[0m" end
def red;            "\033[31m#{self}\033[0m" end
def green;          "\033[32m#{self}\033[0m" end
def brown;          "\033[33m#{self}\033[0m" end
def blue;           "\033[34m#{self}\033[0m" end
def magenta;        "\033[35m#{self}\033[0m" end
def cyan;           "\033[36m#{self}\033[0m" end
def gray;           "\033[37m#{self}\033[0m" end
def bg_black;       "\033[40m#{self}\033[0m" end
def bg_red;         "\033[41m#{self}\033[0m" end
def bg_green;       "\033[42m#{self}\033[0m" end
def bg_brown;       "\033[43m#{self}\033[0m" end
def bg_blue;        "\033[44m#{self}\033[0m" end
def bg_magenta;     "\033[45m#{self}\033[0m" end
def bg_cyan;        "\033[46m#{self}\033[0m" end
def bg_gray;        "\033[47m#{self}\033[0m" end
def bold;           "\033[1m#{self}\033[22m" end
def reverse_color;  "\033[7m#{self}\033[27m" end
end

##########################################
# Helper functions
def info(message)
	puts "[info]    #{message}".gray
end

def notice(message)
	puts "[notice]  #{message}".green
end

def warning(message)
	puts "[warning] #{message}".blue
end

def error(message)
	puts "[error]   #{message}".red
end
#
##########################################


puts ' _   _       _ _              _               '
puts '| | | |     (_) |            | |              '
puts '| |_| | __ _ _| | _____ _   _| | _____ _ __   '
puts '|  _  |/ _` | | |/ / _ \ | | | |/ / _ \ \'_ \ '
puts '| | | | (_| | |   <  __/ |_| |   <  __/ | | | '
puts '\_| |_/\__,_|_|_|\_\___|\__,_|_|\_\___|_| |_| '
puts '--------------------------------------------- '
puts '         The Haiku package builder            '
puts "                Version #{@version}"
puts ''

# Load some basic platform info
@hostname = `uname -n`
@platform = `uname -s`
@architecture = `uname -m`
@revision = `uname -v`.to_s.split(' ')[0]
@threads = 1
@settings = []

@current_build = 0

# Clean up vars
@hostname.delete!("\n")
@platform.delete!("\n")
@architecture.delete!("\n")

begin
	if @platform == "Linux"
		settings_dir = `echo -n ~`
		warning("Running on Linux. We don't support non-Haiku platforms yet.")
		@threads = open('/proc/cpuinfo') { |f| f.grep(/^processor/) }.count
	elsif @platform == "Haiku"
		settings_dir = `finddir B_USER_SETTINGS_DIRECTORY`
		settings_dir.delete!("\n")
		@threads = `sysinfo | grep 'CPU #' | wc -l`.to_i
	end
	# Load settings YAML
	info("Load settings from #{settings_dir}/haikeuken.yml")
	@settings = YAML::load_file("#{settings_dir}/haikeuken.yml")
rescue
	error("Problem loading configuration file at #{settings_dir}/haikeuken.yml")
	exit 1
end

pp @settings
puts ""

# Check for default hostname
if @hostname == "shredder"
	error("Default hostname of #{@hostname} detected. Change it to something unique.")
	exit 1
end
if @settings['general']['hostname']
	@hostname = @settings['general']['hostname']
end

info("Starting buildslave on #{@hostname} (#{@platform}, #{@architecture})")

# new hotness
@remote_api = "#{@settings['server']['url']}/api/v1"

@porter_arguments = "-y -v --no-dependencies -j#{@threads}"

#puts @settings.inspect

def heartbeat()
	while true
	info("heartbeat <3")

	uri = URI("#{@remote_api}/heartbeat/#{@hostname}")
	begin
	Net::HTTP.post_form uri, {"token" => @settings['general']['token'],
		"architecture" => @architecture, "version" => @version,
		"revision" => @revision, "platform" => @platform,
		"threads" => @threads,
		"build" => (@current_build != nil) ? @current_build : 0}
	rescue
		warning("Server #{uri} heartbeat failure.")
	end
	sleep(10.0)
	end
end

def getwork()
	uri = URI("#{@remote_api}/work/#{@hostname}?token=#{@settings['general']['token']}")
	begin
		json = JSON.parse(Net::HTTP.get(uri))
	rescue
		error("Server #{uri} returned invalid JSON data!")
		return nil
	end
	if json.keys.include?("error")
		error("Server error: #{json.fetch("error", "unknown")}")
		return nil
	end
	return json
end


def postwork(result, buildlog, build_id)
	uri = URI("#{@remote_api}/work/#{@hostname}?token=#{@settings['general']['token']}")

	begin
		Net::HTTP.post_form uri, {"token" => @settings['general']['token'],
			"build_id" => build_id.to_i, "result" => result.to_i,
			"details" => buildlog}
	rescue
		error("Server #{uri} did not accept work!")
		return nil
	end
end


def refrepo()
	# Clone or update haikuporter
	if ! Dir.exists?("./haikuporter")
		system 'git clone https://github.com/haikuports/haikuporter.git ./haikuporter'
	else
		Dir.chdir("./haikuporter")
		system 'git pull --rebase'
		Dir.chdir(@settings['general']['work_path'])
	end

	# Check for haikuporter
	if ! File.exist?("./haikuporter/haikuporter")
		puts "Haikuporter missing after clone / update!"
		exit 1
	end

	# Clone or update haikuports
	if ! Dir.exists?("./haikuports")
		system 'git clone https://github.com/haikuports/haikuports.git ./haikuports'
	else
		Dir.chdir("./haikuports")
		system 'git pull --rebase'
		Dir.chdir(@settings['general']['work_path'])
	end
end


def main()
	while true
	# Disabled for testing
	notice("Refreshing repos...")
	refrepo()

	info("Checking for new work...")
	work = getwork()

	# The server could also return a list of tasks,
	# and we could do work.each. For now we just
	# do one task.
	if work == nil
		error("Invalid response from server!")
		exit 1
	end

	command = work.fetch('command', nil)

	if command == 'none'
		notice("No work available")
		return 0
	end

	notice("#{command} received")

	if command == "build"
		build = work.fetch(command, nil)
		@current_build = build.fetch('id', nil)
		notice("Building #{build['name']}-#{build['version']}-#{build['revision']}")

		# Clean
		Open3.capture2e("#{@settings['general']['work_path']}/haikuporter/haikuporter " \
			"#{@porter_arguments} -c #{build['name']}-#{build['version']}")

		worklog, result = Open3.capture2e("#{@settings['general']['work_path']}/haikuporter/haikuporter " \
			"#{@porter_arguments} #{build['name']}-#{build['version']}")

		postwork(result, worklog, build['id'])
	else
		notice("Unknown command from server!")
	end

	notice("Resting for #{@rest_period} seconds...")
	sleep(@rest_period)
	end
end

info("Haiku Package Build System Client #{@version}")
info("  Server: #{@settings['server']['url']}")
info("  Work Path: #{@settings['general']['work_path']}")
info("  Threads: #{@threads}")
puts ""
notice("Entering main work loop")

# Create work_path if it doesn't exist
if ! Dir.exists?(@settings['general']['work_path'])
	Dir.mkdir(@settings['general']['work_path'])
end
Dir.chdir(@settings['general']['work_path'])


# Set up our threads
hbThread = Thread.new{heartbeat()}
mainThread = Thread.new{main()}
hbThread.run
mainThread.run

# Reunited at last
hbThread.join
mainThread.join
