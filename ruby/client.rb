#!/bin/ruby

# Haikeuken buildslave script
##############################################
# Copyright 2014 - 2015 Alexander von Gluck IV
# Released under the terms of the GPLv3
##############################################

@version = "0.2"
@rest_period = 5.0

##########################################
# Requirements
##########################################
require 'json'
require 'net/http'
require 'yaml'
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
def warning(message)
	puts "Warning: #{message}".blue
end

def error(message)
	puts "Error: #{message}".red
	exit 1
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

# Clean up vars
@hostname.delete!("\n")
@platform.delete!("\n")
@architecture.delete!("\n")

begin
	if @platform == "Linux"
		settings_dir = `echo -n ~`
		warning("Running on Linux. We don't support non-native platforms yet.")
	elsif @platform == "Haiku"
		settings_dir = `finddir B_USER_SETTINGS_DIRECTORY`
		settings_dir.delete!("\n")
	end
	# Load settings YAML
	@settings = YAML::load_file("#{settings_dir}/haikeuken.yml")
rescue
	error("Problem loading configuration file at #{settings_dir}/haikeuken.yml")
end

# Check for default hostname
if @hostname == "shredder"
	error("Default hostname of #{@hostname} detected. Change it to something unique.")
end
if @settings['general']['hostname']
	@hostname = @settings['general']['hostname']
end

puts "Starting buildslave on #{@hostname} (#{@platform}, #{@architecture})"

threads = `sysinfo | grep 'CPU #' | wc -l`.to_i

# old + busted
@remote_uri = "#{@settings['server']['url']}/builders/#{@hostname}"

# new hotness
@remote_api = "#{@settings['server']['url']}/api/v1"

@porter_arguments = "-y -v --no-dependencies"

#puts @settings.inspect

def heartbeat()
	uri = URI("#{@remote_api}/heartbeat/#{@hostname}")
	begin
	Net::HTTP.post_form uri, {"token" => @settings['general']['token'],
		"architecture" => @architecture, "version" => @version,
		"revision" => @revision, "platform" => @platform}
	rescue
		puts "=========================================="
		puts "Error: Server #{uri}"
		puts "=========================================="
		#log.close
		return nil
	end
end

def getwork()
	uri = URI("#{@remote_uri}/getwork?token=#{@settings['general']['token']}")
	begin
		json = JSON.parse(Net::HTTP.get(uri))
	rescue
		puts "=========================================="
		puts "Error: Server #{uri}"
		puts "  Returned invalid JSON data!"
		return nil
	end
	return json
end


def putwork(status, buildlog, build_id)
	uri = URI("#{@remote_uri}/putwork")

	#log = File.open(buildlog, "rb")

	begin
		Net::HTTP.post_form uri, {"token" => @settings['general']['token'],
			"status" => status, "build_id" => build_id,
			"result" => buildlog}
		#Net::HTTP.start(uri.hostname, uri.port) do |http|
		#	http.request(req)
		#end
	rescue
		puts "=========================================="
		puts "Error: Server #{uri}"
		puts "=========================================="
		#log.close
		return nil
	end
	#log.close
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


def loop()
	puts "+ Checking for new work..."

	work = getwork()

	# The server could also return a list of tasks,
	# and we could do work.each. For now we just
	# do one task.

	if work == nil or work.count == 0
		puts "- No work available"
		return 0
	end

	work.each do |task|
		puts "+ Work received"
		#worklog = "/tmp/#{task['name']}-#{task['version']}-#{task['revision']}.log"
		puts "+ Building #{task['name']}-#{task['version']}-#{task['revision']}"
#		worklog, result = Open3.capture2e("#{@settings['general']['work_path']}/haikuporter/haikuporter",
#			@porter_arguments, "#{task['name']}-#{task['version']}")
#		#result = system "#{@settings['general']['work_path']}/haikuporter/haikuporter #{@porter_arguments} #{task['name']}-#{task['version']} &> #{worklog}"
		worklog = "quack!"
		result = false
		status = result ? "OK" : "Fail"
		putwork(status, worklog, task['id'])
    end
end

puts "Haiku Package Build System Client #{@version}"
puts "  Server: #{@settings['server']['url']}"
puts "  Work Path: #{@settings['general']['work_path']}"
puts ""
puts "+ Entering main work loop..."

# Create work_path if it doesn't exist
if ! Dir.exists?(@settings['general']['work_path'])
	Dir.mkdir(@settings['general']['work_path'])
end
Dir.chdir(@settings['general']['work_path'])
	
while(1)
	# Disabled for testing
	#puts "+ Refreshing repos..."
	#refrepo()

	heartbeat

	loop()
	puts "+ Resting for #{@rest_period} seconds..."
	sleep(@rest_period)
end
