module Spree
  class AlipayTransaction < ActiveRecord::Base
      has_many :payments, :as => :source
  end
end