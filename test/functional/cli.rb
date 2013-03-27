require File.join(File.dirname(__FILE__), '_lib.rb')
require 'mosql/cli'

class MoSQL::Test::Functional::CLITest < MoSQL::Test::Functional
  TEST_MAP = <<EOF
---
mosql_test:
  collection:
    :meta:
      :table: sqltable
      :callback: test/fixtures/collection_callback
    :columns:
      - _id: TEXT
      - var: INTEGER
  renameid:
    :meta:
      :table: sqltable2
    :columns:
      - id:
        :source: _id
        :type: TEXT
      - goats: INTEGER
EOF

  def fake_cli
    # This is a hack. We should refactor cli.rb to be more testable.
    MoSQL::CLI.any_instance.expects(:setup_signal_handlers)
    cli = MoSQL::CLI.new([])
    cli.instance_variable_set(:@mongo, mongo)
    cli.instance_variable_set(:@schemamap, @map)
    cli.instance_variable_set(:@sql, @adapter)
    cli.instance_variable_set(:@options, {})
    @map.init_callbacks(@adapter.db)
    cli
  end

  before do
    @map = MoSQL::Schema.new(YAML.load(TEST_MAP))
    @adapter = MoSQL::SQLAdapter.new(@map, sql_test_uri)

    @sequel.drop_table?(:sqltable)
    @sequel.drop_table?(:sqltable2)
    @map.create_schema(@sequel)

    @cli = fake_cli

    @callback = @map.callback_for_ns('mosql_test.collection')
  end

  it 'handle "u" ops without _id' do
    o = { '_id' => BSON::ObjectId.new, 'var' => 17 }
    @callback.expects(:after_upsert).with('_id' => o['_id'], 'var' => 27)
    @adapter.upsert_ns('mosql_test.collection', o)
    @cli.handle_op({ 'ns' => 'mosql_test.collection',
                     'op' => 'u',
                     'o2' => { '_id' => o['_id'] },
                     'o'  => { 'var' => 27 }
                   })
    assert_equal(27, sequel[:sqltable].where(:_id => o['_id'].to_s).select.first[:var])
  end

  it 'handle "d" ops with BSON::ObjectIds' do
    o = { '_id' => BSON::ObjectId.new, 'var' => 17 }
    @adapter.upsert_ns('mosql_test.collection', o)
    @callback.expects(:after_delete).with('_id' => o['_id'])

    @cli.handle_op({ 'ns' => 'mosql_test.collection',
                     'op' => 'd',
                     'o' => { '_id' => o['_id'] },
                   })
    assert_equal(0, sequel[:sqltable].where(:_id => o['_id'].to_s).count)
  end

  it 'handle "u" ops with $set and BSON::ObjectIDs' do
    o = { '_id' => BSON::ObjectId.new, 'var' => 17 }
    @adapter.upsert_ns('mosql_test.collection', o)

    # $set's are currently a bit of a hack where we read the object
    # from the db, so make sure the new object exists in mongo
    connect_mongo['mosql_test']['collection'].insert(o.merge('var' => 100),
                                                     :w => 1)

    @callback.expects(:after_upsert).with('_id' => o['_id'],
                                          'var' => 100)

    @cli.handle_op({ 'ns' => 'mosql_test.collection',
                     'op' => 'u',
                     'o2' => { '_id' => o['_id'] },
                     'o'  => { '$set' => { 'var' => 100 } },
                   })
    assert_equal(100, sequel[:sqltable].where(:_id => o['_id'].to_s).select.first[:var])
  end

  it 'handle "u" ops with $set and a renamed _id' do
    o = { '_id' => BSON::ObjectId.new, 'goats' => 96 }
    @adapter.upsert_ns('mosql_test.renameid', o)

    # $set's are currently a bit of a hack where we read the object
    # from the db, so make sure the new object exists in mongo
    connect_mongo['mosql_test']['renameid'].insert(o.merge('goats' => 0),
                                                   :w => 1)

    @cli.handle_op({ 'ns' => 'mosql_test.renameid',
                     'op' => 'u',
                     'o2' => { '_id' => o['_id'] },
                     'o'  => { '$set' => { 'goats' => 0 } },
                   })
    assert_equal(0, sequel[:sqltable2].where(:id => o['_id'].to_s).select.first[:goats])
  end

  it 'handles "d" ops with a renamed id' do
    o = { '_id' => BSON::ObjectId.new, 'goats' => 1 }
    @adapter.upsert_ns('mosql_test.renameid', o)

    @cli.handle_op({ 'ns' => 'mosql_test.renameid',
                     'op' => 'd',
                     'o' => { '_id' => o['_id'] },
                   })
    assert_equal(0, sequel[:sqltable2].where(:id => o['_id'].to_s).count)
  end

  describe '.bulk_upsert' do
    it 'inserts multiple rows' do
      objs = [
              { '_id' => BSON::ObjectId.new, 'var' => 0 },
              { '_id' => BSON::ObjectId.new, 'var' => 1 },
              { '_id' => BSON::ObjectId.new, 'var' => 3 },
             ].map { |o| @map.transform('mosql_test.collection', o) }

      @cli.bulk_upsert(sequel[:sqltable], 'mosql_test.collection',
                       objs)

      assert(sequel[:sqltable].where(:_id => objs[0].first, :var => 0).count)
      assert(sequel[:sqltable].where(:_id => objs[1].first, :var => 1).count)
      assert(sequel[:sqltable].where(:_id => objs[2].first, :var => 3).count)
    end

    it 'upserts' do
      _id = BSON::ObjectId.new
      objs = [
              { '_id' => _id, 'var' => 0 },
              { '_id' => BSON::ObjectId.new, 'var' => 1 },
              { '_id' => BSON::ObjectId.new, 'var' => 3 },
             ].map { |o| @map.transform('mosql_test.collection', o) }

      @cli.bulk_upsert(sequel[:sqltable], 'mosql_test.collection',
                       objs)

      newobjs = [
                 { '_id' => _id, 'var' => 117 },
                 { '_id' => BSON::ObjectId.new, 'var' => 32 },
                ].map { |o| @map.transform('mosql_test.collection', o) }
      @cli.bulk_upsert(sequel[:sqltable], 'mosql_test.collection',
                       newobjs)


      assert(sequel[:sqltable].where(:_id => newobjs[0].first, :var => 117).count)
      assert(sequel[:sqltable].where(:_id => newobjs[1].first, :var => 32).count)
    end
  end
end
