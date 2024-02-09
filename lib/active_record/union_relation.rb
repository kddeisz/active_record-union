# frozen_string_literal: true

require "active_record"
require "active_record/union_relation/version"

module ActiveRecord
  class UnionRelation
    class Error < StandardError
    end

    # Unions require that the number of columns coming from each subrelation all
    # match. When we pull the attributes out an instantiate the actual objects,
    # we then map them back to the original attribute names.
    class MismatchedColumnsError < Error
      def initialize(columns, sources)
        super("Expected #{columns.length} columns but got #{sources.length}")
      end
    end

    # If you attempt to use a union before you've added any subqueries, we'll
    # raise this error so there's not some weird undefined method behavior.
    class NoConfiguredSubqueriesError < Error
      def initialize
        super("No subqueries have been configured for this union")
      end
    end

    # This represents a combination of an ActiveRecord::Relation and a set of
    # columns that it will pull.
    class Subquery
      # Sometimes you need some columns in some subqeries that you don't need in
      # others. In order to accomplish that and still maintain the matching
      # number of columns, you can put a null in space of a column instead.
      NULL = Arel.sql("NULL")

      attr_reader :relation, :model_name, :sources

      def initialize(relation, sources)
        @relation = relation
        @model_name = relation.model.name
        @sources = sources.map { |source| source ? source.to_s : NULL }
      end

      def to_arel(columns, discriminator)
        relation.select(
          Arel.sql("'#{model_name}'").as(quote_column_name(discriminator)),
          *sources
            .zip(columns)
            .map do |(source, column)|
              Arel.sql(source.to_s).as(quote_column_name(column))
            end
        ).arel
      end

      def to_mapping(columns)
        # Remove the scope_name/table_name when using table_name.column
        sources_without_scope = sources.map { _1.split(".").last }
        [model_name, columns.zip(sources_without_scope).to_h]
      end

      private

      def quote_column_name(name)
        relation.model.connection.quote_column_name(name)
      end
    end

    attr_reader :columns, :discriminator, :subqueries

    def initialize(columns, discriminator)
      @columns = columns.map(&:to_s)
      @discriminator = discriminator
      @subqueries = []
    end

    # Adds a subquery to the overall union.
    def add(relation, *sources)
      if columns.length != sources.length
        raise MismatchedColumnsError.new(columns, sources)
      end

      subqueries << Subquery.new(relation, sources)
    end

    # Creates an ActiveRecord::Relation object that will pull all of the
    # subqueries together.
    def all
      raise NoConfiguredSubqueriesError if subqueries.empty?

      model = subqueries.first.relation.model
      subclass_for(model).from(union_for(model)).select(discriminator, *columns)
    end

    private

    def subclass_for(model)
      discriminator = self.discriminator
      mappings = subqueries.to_h { |subquery| subquery.to_mapping(columns) }

      Class.new(model) do
        # Set the inheritance column and register the discriminator as a string
        # column so that Active Record will instantiate the right subclass.
        self.inheritance_column = discriminator
        attribute inheritance_column, :string

        define_singleton_method(:instantiate) do |attrs, columns = {}, &block|
          mapped = {}
          mapping = mappings[attrs[inheritance_column]]

          # Map the result set columns back to their original source column
          # names. This ensures that even though the UNION saw them as the same
          # columns our resulting records see them as their original names.
          attrs.each do |key, value|
            case mapping[key]
            when Subquery::NULL
              # Ignore columns that didn't have a value.
            when nil
              # If we don't have a mapping for this column, then it's the
              # discriminator. Map that column directly.
              mapped[key] = value
            else
              # Otherwise, use the mapping to map the column back to its
              # original name.
              mapped[mapping[key]] = value
            end
          end

          # Now that we've mapped all of the columns, we can call super with the
          # mapped values.
          super(mapped, columns, &block)
        end

        # Override the default find_sti_class method because it does sanity
        # checks to ensure that the class you're trying to instantiate is a
        # subclass of the current class. Since we want to explicitly _not_ do
        # that, we will instead just check that it is a valid model class.
        define_singleton_method(:find_sti_class) do |type_name|
          type = type_name.constantize
          type < ActiveRecord::Base ? type : super(type_name)
        end
      end
    end

    def union_for(model)
      Arel::Nodes::As.new(
        subqueries
          .map { |subquery| subquery.to_arel(columns, discriminator).ast }
          .inject { |left, right| Arel::Nodes::Union.new(left, right) },
        Arel.sql(model.connection.quote_table_name("union"))
      )
    end
  end

  # Unions require that you have an equal number of columns from each
  # subquery. The columns argument being passed here is any number of
  # symbols that represent the columns that will be queried. When you then go
  # to add sources into the union you'll need to pass the same number of
  # columns.
  #
  # One additional column will be added to the query in order to discriminate
  # between all of the unioned types. Then when the objects are going to be
  # instantiated, we map the columns back to their original names.
  def self.union(*columns, discriminator: "discriminator")
    UnionRelation.new(columns, discriminator).tap { |union| yield union }.all
  end
end
