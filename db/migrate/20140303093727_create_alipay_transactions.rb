class CreateAlipayTransactions < ActiveRecord::Migration
  def change
    create_table :spree_alipay_transactions do |t|
      t.string :buyer_email
      t.string :buyer_id
      t.string :exterface
      t.string :trade_no
      t.string :out_trade_no
      t.string :payment_type
      t.string :total_fee
      t.string :trade_status

      t.timestamps
    end
  end
end
