require 'dotenv/load'
### CONFIGURATION
#################

# CONNECTION
TOKEN           = ENV['TOKEN']
TOKEN_SECRET    = ENV['TOKEN_SECRET']
CONSUMER_KEY    = ENV['CONSUMER_KEY']
CONSUMER_SECRET = ENV['CONSUMER_SECRET']
ENDPOINT        = ENV['ENDPOINT']

# OTHER
MASTER_LANGUAGE   = ENV['MASTER_LANGUAGE']
time              = Time.new
FOLDER_NAME       = './export_' + time.strftime("%Y-%m-%d\T%H:%M:%S")
SUMMARY_FIELD     = 'body__c'
DESCRIPTION_FIELD = 'description__c'
CHANNELS          = 'application+sites+csp'

# CSV SETTINGS
DATE_FORMAT       = 'yyyy-MM-dd'
DATE_TIME_FORMAT  = 'yyyy-MM-dd HH:mm:ss'
CSV_ENCODING      = Encoding::default_external.to_s # UTF-8
CSV_SEPARATOR     = ','
RTA_ENCODING      = Encoding::default_external.to_s # UTF-8

### SCRIPT - DON'T TOUCH
######################
require 'desk_api'
require 'open_uri_redirections'
require 'csv'
require 'rails-html-sanitizer'

full_sanitizer = Rails::Html::FullSanitizer.new

puts 'Starting to export to ' + FOLDER_NAME

# setup Api
DeskApi.configure do |config|
  config.token           = TOKEN
  config.token_secret    = TOKEN_SECRET
  config.consumer_key    = CONSUMER_KEY
  config.consumer_secret = CONSUMER_SECRET
  config.endpoint = ENDPOINT
end

# create the file system
Dir.mkdir File.expand_path(FOLDER_NAME) unless Dir.exists?(File.expand_path(FOLDER_NAME))
['data', 'data/images', 'data/attachments'].each do |dir|
  Dir.mkdir("#{File.expand_path(FOLDER_NAME)}/#{dir}") unless Dir.exists?("#{File.expand_path(FOLDER_NAME)}/#{dir}")
end

# create the csv file
CSV.open("#{File.expand_path(FOLDER_NAME)}/articles.csv", 'wb', {
  col_sep: CSV_SEPARATOR,
  encoding: CSV_ENCODING
}) do |csv|
  # write the properties file
  File.open("#{File.expand_path(FOLDER_NAME)}/articles.properties", 'wb') do |file|
    file.write [
      "DateFormat=#{DATE_FORMAT}",
      "DateTimeFormat=#{DATE_TIME_FORMAT}",
      "CSVEncoding=#{CSV_ENCODING}",
      "CSVSeparator=#{CSV_SEPARATOR}",
      "RTAEncoding=#{RTA_ENCODING}"
    ].join("\n")
  end

  # write the headers
  csv << ['Id', 'isMaster Language', 'In support center', 'Title', 'Body', 'File name', 'Category', 'Channels', 'Language', 'quickcode', 'brands']

  # get the topics
  topics = DeskApi.topics

  begin
    # run through the topics
    topics.entries.each do |topic|

      puts '======'
      puts 'Looking at ' + topic.name
      next unless topic.in_support_center

      puts 'Fetching ' + topic.name


      # fetch the articles
      articles = topic.articles

      begin
        # run through the articles
        articles.embed(:brands).entries.each do |article|
          puts '  ----'
          puts '  Looking at ' + article.id.to_s + ' : ' + article.subject
          puts '  Fetching ' + article.subject

          # fetch attachments
          puts '      Fetching Attachments'
          attachments = article.attachments
          attachments_folder  = "attachments/#{article.href[/\d+$/]}"
          Dir.mkdir("#{File.expand_path(FOLDER_NAME)}/data/#{attachments_folder}") rescue 0

          begin
            attachments.entries.each do |attachment|
              attachmentResponse = DeskApi.get attachment.url

              puts '      > ' + attachment.url + ' -> ' + attachment.file_name
              File.open("#{File.expand_path(FOLDER_NAME)}/data/#{attachments_folder}/#{attachment.file_name}", 'wb') do |file|
                file.write(attachmentResponse.body)
              end
            end
          end

          # delete attachments folder if empty
          Dir.delete("#{File.expand_path(FOLDER_NAME)}/data/#{attachments_folder}") rescue 0

          # fetch the translations
          translations = article.translations

          begin
            # run through the translations
            translations.entries.each do |translation|
              is_master   = translation.locale.downcase == MASTER_LANGUAGE.downcase
              file_name   = "data/#{article.href[/\d+$/]}_#{translation.locale}.html"
              img_folder  = "images/#{article.href[/\d+$/]}_#{translation.locale}"

              puts '      Fetching Translation ' + translation.locale

              # add the article to the csv
              csv << [
                article.id.to_s,
                is_master ? 1 : 0,
                article.in_support_center,
                translation.subject,
                full_sanitizer.sanitize(translation.body),
                file_name,
                is_master ? topic.name : '',
                is_master ? CHANNELS : '',
                translation.locale,
                article.quickcode,
                article.brands.map{|k| "#{k.name}"}.join(',')
              ]

              # create an image folder for this article
              Dir.mkdir("#{File.expand_path(FOLDER_NAME)}/data/#{img_folder}") rescue 0

              # write the article
              File.open("#{File.expand_path(FOLDER_NAME)}/#{file_name}", 'wb') do |file|
                # extract images and save
                body = translation.body.tap do |content|
                  content.scan(/<img[^>]+src="([^">]+)"/).each do |image|
                    begin

                      puts '      ? Looking at image ' + image.to_s

                      image_uri = URI::parse(image.first)

                      if not image_uri.scheme
                        # Must Authenticate local images
                        require 'net/http'
                        http = Net::HTTP.new('coachmeplus.desk.com', 443)
                        http.use_ssl = true
                        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
                        headers = {
                          'Cookie' => "authenticated_customer_credentials=#{ENV['AUTHENTICATED_CUSTOMER_CREDENTIALS']};",
                        }
                        resp = http.request_get(image_uri.to_s, headers)
                        redirectS3Location = resp['Location']
                        image_uri = URI::parse(redirectS3Location)
                      end

                      image_name = Digest::MD5.hexdigest image_uri.to_s
                      puts '      > ' + image_uri.to_s + ' -> ' + image_name
                      File.open("#{File.expand_path(FOLDER_NAME)}/data/#{img_folder}/#{image_name}", 'wb') do |file|
                        file.print open(image_uri.to_s, allow_redirections: :all).read
                      end

                      # change the image src to the new path
                      search = Regexp.new(Regexp.escape(image.first))
                      content.gsub!(search, "#{img_folder}/#{image_name}")
                    rescue StandardError => e
                      puts e.message
                      puts e.backtrace.inspect
                    end
                  end
                end

                file.write body
              end

              # delete image folder if empty
              Dir.delete("#{File.expand_path(FOLDER_NAME)}/data/#{img_folder}") rescue 0
            end

          end while translations = translations.next
        end

      end while articles = articles.next
    end

  end while topics = topics.next
end

puts 'Finished Successfully'
