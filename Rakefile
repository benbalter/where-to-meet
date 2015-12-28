$LOAD_PATH << File.expand_path(File.dirname(__FILE__))

require 'rubygems'
require 'bundler'

Bundler.require(:default)

require 'sinatra/asset_pipeline/task'
require 'where_to_meet'

Sinatra::AssetPipeline::Task.define! WhereToMeet
