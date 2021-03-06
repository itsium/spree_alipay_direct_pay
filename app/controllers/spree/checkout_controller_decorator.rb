#encoding: utf-8
require 'httparty'

module Spree
  CheckoutController.class_eval do

    # cattr_accessor :skip_payment_methods
    # self.skip_payment_methods = [:alipay_notify, :alipay_done]#, :tenpay_notify, :tenpay_done
    # before_filter :alipay_checkout_hook, :only => [:update]
    # skip_before_filter :load_order, :ensure_valid_state, :only => self.skip_payment_methods
    # # #invoid WARNING: Can't verify CSRF token authenticity
    # skip_before_filter :verify_authenticity_token, :only => self.skip_payment_methods
    # # # these two filters is from spree_auth_devise
    # skip_before_filter :check_registration, :check_authorization, :only=> self.skip_payment_methods


    cattr_accessor :skip_payment_methods
    self.skip_payment_methods = [:alipay_notify, :alipay_done]#, :tenpay_notify, :tenpay_done
    before_filter :alipay_checkout_hook, :only => [:update]
    skip_before_filter :load_order, :ensure_valid_state, :setup_for_current_state, :ensure_order_not_completed, :ensure_sufficient_stock_lines, :ensure_checkout_allowed, :only => [:alipay_notify]
    skip_before_filter :ensure_valid_state, :ensure_checkout_allowed, :only=> [:alipay_done]
    # #invoid WARNING: Can't verify CSRF token authenticity
    skip_before_filter :verify_authenticity_token, :only => self.skip_payment_methods
    # # these two filters is from spree_auth_devise
    skip_before_filter :check_registration, :check_authorization, :only=> self.skip_payment_methods

# https://cashier.alipay.com/standard/result/rnPaymentResult.htm?payNo=201403046HRC9800&orderDetailUrl=http%3A%2F%2Ftradeexprod-pool%2Ftile%2Fservice%2Fhome%3AcashierOrderDetail.tile&outBizNo=2014030476031300&msg=%7B%7D&bizIdentity=trade20001&orderId=030453a55f84a3f0737eba6014277000
    # def before_address
    #   @order.bill_address ||= Address.default
    #   # byebug
    #   if @order.checkout_steps.include? "delivery"
    #     @order.ship_address ||= Address.default
    #     if spree_current_user
    #       order_index = spree_current_user.orders.count - 2 
    #       if order_index >= 0
    #         @order.bill_address = spree_current_user.orders[order_index].ship_address
    #         @order.ship_address = @order.bill_address
    #       end
    #     end
    #   end
    # end

# _type=trade_status_sync&out_trade_no=R571153102&payment_type=1&seller_email=mybox%40imybox.com.cn&seller_id=2088701730421315&subject=%E8%AE%A2%E5%8D%95%E7%BC%96%E5%8F%B7%3AR571153102&total_fee=0.01&trade_no=2014030476157800&trade_status=TRADE_SUCCESS&sign=fda04321c8b4afb8b45203df1b6fc9fb&sign_type=MD5
    #   def before_delivery
    #     byebug
    #     return if params[:order].present?

    #     packages = @order.shipments.map { |s| s.to_package }
    #     @differentiator = Spree::Stock::Differentiator.new(@order, packages)
    #   end

    def alipay_done
      
      payment_return = ActiveMerchant::Billing::Integrations::Alipay::Return.new(request.query_string)
      retrieve_order(request.params['out_trade_no'])
      logger.debug "[       DEBUG       ] In Done #{@order.inspect}"
      if @order.present?
        session[:order_id] = nil
        flash[:success] = Spree.t(:order_success)
        redirect_to completion_route
      else
        redirect_to edit_order_checkout_url(@order, :state => "payment")
      end
    end
    # WHY PAYMENT NOT EXIST ? 
    def alipay_notify
      
      notification = ActiveMerchant::Billing::Integrations::Alipay::Notification.new(request.raw_post)
      retrieve_order(notification.out_trade_no)
      logger.debug "[       DEBUG       ] In Notify #{@order.inspect}"
      if @order.present? and verify_sign(request.raw_post) and valid_alipay_notification?(notification, @order.payments.first.payment_method.preferred_partner)
        if (notification.trade_status == "TRADE_SUCCESS" || notification.trade_status == "TRADE_FINISHED" )
          @order.payments.first.complete! if @order.payment_state != "paid"
          @order.update_attributes({:state => "complete", :completed_at => Time.now})
          @order.update!
          @order.finalize!
        else
          @order.payments.first.failure!
        end
        render text: "success" 
      else
        render text: "fail" 
      end
    end

    def verify_sign(query_string)
      params = CGI::parse(query_string)
      sign_type = params.delete("sign_type").try(:join)
      sign = params.delete("sign").try(:join)
      sign.downcase == Digest::MD5.hexdigest((params.sort.collect{|s|s[0]+"="+s[1].join}).join("&")+@order.payments.first.payment_method.preferred_sign)
    end

    #https://github.com/flyerhzm/donatecn
    #demo for activemerchant_patch_for_china
    #since alipay_full_service_url is working, it is only for debug for now.
    def alipay_checkout_payment
       payment_method =  PaymentMethod.find(params[:payment_method_id])
       #Rails.logger.debug "@payment_method=#{@payment_method.inspect}"       
       Rails.logger.debug "[DEBUG] alipay_full_service_url:"+aplipay_full_service_url(@order, payment_method)
       # notice that load_order would call before_payment, if 'http==put' and 'order.state == payment', the payments will be deleted. 
       # so we have to create payment again
       @order.payments.create(:amount => @order.total, :payment_method_id => payment_method.id)
       @order.payments.first.started_processing!

       #redirect_to_alipay_gateway(:subject => "donatecn", :body => "donatecn", :amount => @donate.amount, :out_trade_no => "123", :notify_url => pay_fu.alipay_transactions_notify_url)
    end
    
    private

    def alipay_checkout_hook
#logger.debug "----before alipay_checkout_hook"    
#all_filters = self.class._process_action_callbacks
#all_filters = all_filters.select{|f| f.kind == :before}
#logger.debug "all before filers:"+all_filters.map(&:filter).inspect  
      return unless (params[:state] == "payment")
      return unless params[:order][:payments_attributes].present?
      payment_method = PaymentMethod.find(params[:order][:payments_attributes].first[:payment_method_id])
      if payment_method.kind_of?(BillingIntegration::Alipay)
      
        if @order.update_attributes(object_params) #it would create payments
          if params[:order][:coupon_code] and !params[:order][:coupon_code].blank? and @order.coupon_code.present?
            fire_event('spree.checkout.coupon_code_added', :coupon_code => @order.coupon_code)
          end
        end
       # set_alipay_constant_if_needed 
       # ActiveMerchant::Billing::Integrations::Alipay::KEY
       # ActiveMerchant::Billing::Integrations::Alipay::ACCOUNT
       # gem activemerchant_patch_for_china is using it.
       # should not set when payment_method is updated, after restart server, it would be nil
       # TODO fork the activemerchant_patch_for_china, change constant to class variable
       alipay_helper_klass = ActiveMerchant::Billing::Integrations::Alipay::Helper
       alipay_helper_klass.send(:remove_const, :KEY) if alipay_helper_klass.const_defined?(:KEY)
       alipay_helper_klass.const_set(:KEY, payment_method.preferred_sign)
      
       #redirect_to(alipay_checkout_payment_order_checkout_url(@order, :payment_method_id => payment_method.id))
       redirect_to aplipay_full_service_url(@order, payment_method)
      end
    end
    
    def retrieve_order(order_number)
        @order = Spree::Order.find_by_number(order_number)
        if @order
          #@order.payment.try(:payment_method).try(:provider) #configures ActiveMerchant
        end
        @order
    end
    
    def valid_alipay_notification?(notification, account)
      url = "https://mapi.alipay.com/gateway.do?service=notify_verify"
      result = HTTParty.get(url, query: {partner: account, notify_id: notification.notify_id}).body
      result == 'true'
    end


    def aplipay_full_service_url( order, alipay)
      raise ArgumentError, 'require Spree::BillingIntegration::Alipay' unless alipay.is_a? Spree::BillingIntegration::Alipay
      url = ActiveMerchant::Billing::Integrations::Alipay.service_url+'?'
      helper = ActiveMerchant::Billing::Integrations::Alipay::Helper.new(order.number, alipay.preferred_partner)
      using_direct_pay_service = alipay.preferred_using_direct_pay_service

      if using_direct_pay_service
        helper.total_fee order.total
        helper.service ActiveMerchant::Billing::Integrations::Alipay::Helper::CREATE_DIRECT_PAY_BY_USER
      else
        helper.price order.item_total
        helper.quantity 1
        helper.logistics :type=> 'EXPRESS', :fee=>order.adjustment_total, :payment=>'BUYER_PAY' 
        helper.service ActiveMerchant::Billing::Integrations::Alipay::Helper::TRADE_CREATE_BY_BUYER
      end
        helper.seller :email => alipay.preferred_email
        #url_for is controller instance method, so we have to keep this method in controller instead of model
        helper.notify_url url_for(:only_path => false, :action => 'alipay_notify')
        helper.return_url url_for(:only_path => false, :action => 'alipay_done')
        helper.body "order_detail_description"
        helper.charset "utf-8"
        helper.payment_type 1
        helper.subject "订单编号:#{order.number}"
        helper.sign
        url << helper.form_fields.collect{ |field, value| "#{field}=#{value}" }.join('&')
        URI.encode url # or URI::InvalidURIError    
    end
  end
end
