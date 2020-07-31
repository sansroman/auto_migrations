# load rake
Dir[File.join(File.dirname(__FILE__),'tasks/**/*.rake')].each { |f| load f } if defined?(Rake)

module AutoMigrations
  def self.run
    # Turn off schema_info code for auto-migration
    class << ActiveRecord::Schema
      alias :old_define :define
      attr_accessor :version
      def define(info={}, &block) @version = Time.now.utc.strftime("%Y%m%d%H%M%S"); instance_eval(&block) end
    end

    load(File.join(Rails.root, 'db', 'schema.rb'))
    ActiveRecord::Migration.drop_unused_tables
    ActiveRecord::Migration.drop_unused_indexes
    ActiveRecord::Migration.update_schema_version(ActiveRecord::Schema.version) if ActiveRecord::Schema.version

    class << ActiveRecord::Schema
      alias :define :old_define
    end
  end

  def self.schema_to_migration(with_reset = false)
    schema_in = File.read(File.join(Rails.root, "db", "schema.rb"))
    schema_in.gsub!(/#(.)+\n/, '')
    schema_in.sub!(/ActiveRecord::Schema.define(.+)do[ ]?\n/, '')
    schema_in.gsub!(/^/, '  ')
    schema = "class InitialSchema < ActiveRecord::Migration\n  def self.up\n"
    schema += "    # We're resetting the migrations database...\n" +
              "    drop_table :schema_migrations\n" +
              "    initialize_schema_migrations_table\n\n" if with_reset
    schema += schema_in
    schema << "\n  def self.down\n"
    schema << ((ActiveRecord::VERSION::MAJOR >= 5 ? ActiveRecord::Base.connection.data_sources : ActiveRecord::Base.connection.tables) - %w(schema_info schema_migrations)).map do |table|
                "    drop_table :#{table}\n"
              end.join
    schema << "  end\nend\n"
    migration_file = File.join(Rails.root, "db", "migrate", "001_initial_schema.rb")
    File.open(migration_file, "w") { |f| f << schema }
    puts "Migration created at db/migrate/001_initial_schema.rb"
  end

  def self.included(base)
    base.extend ClassMethods
    class << base
      cattr_accessor :tables_in_schema, :indexes_in_schema
      self.tables_in_schema, self.indexes_in_schema = [], []
      alias_method :method_missing_without_auto_migration, :method_missing
      alias_method :method_missing, :method_missing_with_auto_migration
    end
  end

  module ClassMethods

    def method_missing_with_auto_migration(method, *args, &block)
      case method
      when :create_table
        auto_create_table(method, *args, &block)
      when :add_index
        auto_add_index(method, *args, &block)
      else
        method_missing_without_auto_migration(method, *args, &block)
      end
    end

    def auto_create_table(method, *args, &block)
      table_name = args.shift.to_s
      options    = args.pop || {}

      (self.tables_in_schema ||= []) << table_name

      # Table doesn't exist, create it
      unless (ActiveRecord::VERSION::MAJOR >= 5 ? ActiveRecord::Base.connection.data_sources : ActiveRecord::Base.connection.tables).include?(table_name)
        return method_missing_without_auto_migration(method, *[table_name, options], &block)
      end

      # Grab database columns
      fields_in_db = ActiveRecord::Base.connection.columns(table_name).inject({}) do |hash, column|
        hash[column.name] = column
        hash
      end

      # Grab schema columns (lifted from active_record/connection_adapters/abstract/schema_statements.rb)
      table_definition = create_table_definition table_name, options[:temporary], options[:options]
      primary_key = options[:primary_key] || "id"
      table_definition.primary_key(primary_key) unless options[:id] == false
      yield table_definition
      fields_in_schema = table_definition.columns.inject({}) do |hash, column|
        hash[column.name.to_s] = column
        hash
      end

      # Add fields to db new to schema
      (fields_in_schema.keys - fields_in_db.keys).each do |field|
        column  = fields_in_schema[field]
        options = {:limit => column.limit, :precision => column.precision, :scale => column.scale}
        options[:default] = column.default if !column.default.nil?
        options[:null]    = column.null    if !column.null.nil?
        add_column table_name, column.name, column.type.to_sym, options
      end

      # Remove fields from db no longer in schema
      (fields_in_db.keys - fields_in_schema.keys & fields_in_db.keys).each do |field|
        column = fields_in_db[field]
        remove_column table_name, column.name
      end

      (fields_in_schema.keys & fields_in_db.keys).each do |field|
        if field != primary_key #ActiveRecord::Base.get_primary_key(table_name)
          changed  = false  # flag
          new_type = fields_in_schema[field].type.to_sym
          new_attr = {}

          # First, check if the field type changed
          if fields_in_schema[field].type.to_sym != fields_in_db[field].type.to_sym
            changed = true
          end

          # Special catch for precision/scale, since *both* must be specified together
          # Always include them in the attr struct, but they'll only get applied if changed = true
          new_attr[:precision] = fields_in_schema[field].precision
          new_attr[:scale]     = fields_in_schema[field].scale

          # Next, iterate through our extended attributes, looking for any differences
          # This catches stuff like :null, :precision, etc
          fields_in_schema[field][:options].each_pair do |att,value|
            next unless [:limit, :precision, :scale, :default, :null, :collation, :comment].include?(att)

            if !value.nil?
              value_in_db = fields_in_db[field].send(att)
              value_in_db = value_in_db.to_i if att == :default && new_type == :integer && value_in_db.class == String
              value_in_db = value_in_db.to_f if att == :default && new_type == :float && value_in_db.class == String
              if att == :default && new_type == :boolean && value_in_db.class == String
                value_in_db_to_i = value_in_db.to_i
                value_in_db = false if value_in_db_to_i == 0
                value_in_db = true  if value_in_db_to_i == 1
              end

              if value != value_in_db
                new_attr[att] = value
                changed = true
              end
            end
          end

          # Change the column if applicable
          change_column table_name, field, new_type, new_attr if changed
        end
      end
    end

    def auto_add_index(method, *args, &block)
      table_name = args.shift.to_s
      fields     = Array(args.shift).map(&:to_s)
      options    = args.shift

      index_name = options[:name] if options
      index_name ||= ActiveRecord::Base.connection.index_name(table_name, :column => fields)

      (self.indexes_in_schema ||= []) << index_name

      unless ActiveRecord::Base.connection.indexes(table_name).detect { |i| i.name == index_name }
        method_missing_without_auto_migration(method, *[table_name, fields, options], &block)
      end
    end

    def drop_unused_tables
      ((ActiveRecord::VERSION::MAJOR >= 5 ? ActiveRecord::Base.connection.data_sources : ActiveRecord::Base.connection.tables) - tables_in_schema - %w(schema_info schema_migrations)).each do |table|
        drop_table table
      end
    end

    def drop_unused_indexes
      tables_in_schema.each do |table_name|
        indexes_in_db = ActiveRecord::Base.connection.indexes(table_name).map(&:name)
        (indexes_in_db - indexes_in_schema & indexes_in_db).each do |index_name|
          remove_index table_name, :name => index_name
        end
      end
    end

    def update_schema_version(version)
      if (ActiveRecord::VERSION::MAJOR >= 5 ? ActiveRecord::Base.connection.data_sources : ActiveRecord::Base.connection.tables).include?("schema_migrations")
        ActiveRecord::Base.connection.update("INSERT INTO schema_migrations VALUES ('#{version}')")
      end
      schema_file = File.join(Rails.root, "db", "schema.rb")
      schema = File.read(schema_file)
      schema.sub!(/:version => \d+/, ":version => #{version}")
      File.open(schema_file, "w") { |f| f << schema }
    end

    private
    def create_table_definition(name, temporary, options)
      ActiveRecord::ConnectionAdapters::TableDefinition.new(ActiveRecord::Base.connection, name, {temporary: temporary, options: options} )
    end
  end
end

ActiveRecord::Migration.send :include, AutoMigrations
