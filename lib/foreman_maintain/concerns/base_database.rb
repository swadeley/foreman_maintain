module ForemanMaintain
  module Concerns
    module BaseDatabase
      def data_dir
        '/var/lib/pgsql/data/'
      end

      def configuration
        raise NotImplementedError
      end

      def config_files
        [
          '/etc/systemd/system/postgresql.service'
        ]
      end

      def local?(config = configuration)
        ['localhost', '127.0.0.1', `hostname`.strip].include? config['host']
      end

      def query(sql, config = configuration)
        parse_csv(query_csv(sql, config))
      end

      def query_csv(sql, config = configuration)
        psql(%{COPY (#{sql}) TO STDOUT WITH CSV HEADER}, config)
      end

      def psql(query, config = configuration)
        if ping(config)
          execute(psql_command(config),
                  :stdin => query,
                  :hidden_patterns => [config['password']])
        else
          raise_service_error
        end
      end

      def ping(config = configuration)
        execute?(psql_command(config),
                 :stdin => 'SELECT 1 as ping',
                 :hidden_patterns => [config['password']])
      end

      def backup_file_path(config = configuration)
        dump_file_name = "#{config['database']}_#{Time.now.strftime('%Y-%m-%d_%H-%M-%S')}.dump"
        "#{backup_dir}/#{dump_file_name}.bz2"
      end

      def dump_db(file, config = configuration)
        execute!(dump_command(config) + " > #{file}", :hidden_patterns => [config['password']])
      end

      def backup_local(backup_file, extra_tar_options = {})
        dir = extra_tar_options.fetch(:data_dir, data_dir)
        FileUtils.cd(dir) do
          tar_options = {
            :archive => backup_file,
            :command => 'create',
            :transform => 's,^,var/lib/pgsql/data/,S'
          }.merge(extra_tar_options)
          feature(:tar).run(tar_options)
        end
      end

      # TODO: refactor to use dump_db
      def backup_db_command(file_path, config = configuration)
        pg_dump_cmd = "pg_dump -Fc #{config['database']}"
        "runuser - postgres -c '#{pg_dump_cmd}' | bzip2 -9 > #{file_path}"
      end

      # TODO: remove the backup file path tools from here. Lib Utils::Backup?
      def backup_dir
        @backup_dir ||= File.expand_path(ForemanMaintain.config.db_backup_dir)
      end

      def backup_global_objects(file)
        execute!("runuser - postgres -c 'pg_dumpall -g > #{file}'")
      end

      def perform_backup(config = configuration)
        file_path = backup_file_path(config)
        backup_cmd = backup_db_command(file_path, config)
        execute!(backup_cmd, :hidden_patterns => [config['password']])
        puts "\n Note: Database backup file path - #{file_path}"
        puts "\n In case of any exception, use above dump file to restore DB."
      end

      def table_exist?(table_name)
        sql = <<-SQL
          SELECT EXISTS ( SELECT *
          FROM information_schema.tables WHERE table_name =  '#{table_name}' )
        SQL
        result = query(sql)
        return false if result.nil? || (result && result.empty?)
        result.first['exists'].eql?('t')
      end

      def delete_records_by_ids(tbl_name, rec_ids)
        quotize_rec_ids = rec_ids.map { |el| "'#{el}'" }.join(',')
        unless quotize_rec_ids.empty?
          psql(<<-SQL)
            BEGIN;
             DELETE FROM #{tbl_name} WHERE id IN (#{quotize_rec_ids});
            COMMIT;
          SQL
        end
      end

      def find_base_directory(directory)
        find_dir_containing_file(directory, 'postgresql.conf')
      end

      private

      def base_command(config, command = 'psql')
        "PGPASSWORD='#{config[%(password)]}' "\
        "#{command} -h #{config['host'] || 'localhost'} "\
        " -p #{config['port'] || '5432'} -U #{config['username']}"
      end

      def psql_command(config)
        base_command(config, 'psql') + " -d #{config['database']}"
      end

      def dump_command(config)
        base_command(config, 'pg_dump') + " -Fc #{config['database']}"
      end

      def raise_service_error
        raise Error::Fail, 'Please check whether database service is up & running state.'
      end
    end
  end
end