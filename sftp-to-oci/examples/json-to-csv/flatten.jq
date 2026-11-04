# Flattens batch -> orders[] -> items[] -> discounts[] into one CSV row per
# order/item/discount. An order with no items, or an item with no discounts (empty
# list or key missing), still produces one row with empty cells, like an outer join.
def rows_or_null: if . == null or length == 0 then [null] else . end;

(["batch_id","order_id","status","customer_id","customer_name","city","country",
  "sku","qty","price","discount_code","discount_pct"] | @csv),
( .batch.id as $batch
  | .orders[]
  | . as $o
  | ($o.items | rows_or_null)[] as $i
  | ($i.discounts | rows_or_null)[] as $d
  | [ $batch, $o.orderId, $o.status, $o.customer.id, $o.customer.name,
      $o.customer.address.city, $o.customer.address.country,
      $i.sku, $i.qty, $i.price, $d.code, $d.pct ]
  | @csv )
