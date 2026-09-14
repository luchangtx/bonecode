<template>
  <div class="panel">
    <h2 class="panel__title">{{ title }}</h2>

    <input v-model="keyword" class="panel__input" placeholder="搜索订单号" @keyup.enter="search" />

    <ul class="panel__list">
      <li v-for="(order, index) in filtered" :key="order.id" class="panel__item">
        <span class="panel__index">{{ index + 1 }}</span>
        <span class="panel__id">{{ order.id }}</span>
        <span class="panel__amount" :class="{ 'is-paid': order.paid }">
          ¥{{ order.amount.toFixed(2) }}
        </span>
      </li>
    </ul>

    <p v-if="filtered.length === 0" class="panel__empty">没有匹配的订单</p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

interface Order {
  id: string
  customer: string
  amount: number
  paid: boolean
}

const title = ref<string>('订单列表')
const keyword = ref<string>('')
const orders = ref<Order[]>([])

const filtered = computed<Order[]>(() => {
  const key = keyword.value.trim().toLowerCase()
  if (!key) {
    return orders.value
  }
  return orders.value.filter(
    (order) => order.id.toLowerCase().includes(key) || order.customer.toLowerCase().includes(key)
  )
})

const paidTotal = computed<number>(() =>
  orders.value.filter((order) => order.paid).reduce((sum, order) => sum + order.amount, 0)
)

async function search(): Promise<void> {
  console.log('搜索关键词', keyword.value, '已付合计', paidTotal.value)
}

onMounted(() => {
  orders.value = [
    { id: 'A-1001', customer: '张伟', amount: 1280, paid: true },
    { id: 'A-1002', customer: '李娜', amount: 430.5, paid: false },
    { id: 'A-1003', customer: '王强', amount: 2980, paid: true }
  ]
})
</script>

<style scoped>
.panel {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
  border: 1px solid #e3e5e8;
  border-radius: 8px;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
}

.panel__title {
  margin: 0;
  color: #1f2328;
  font-size: 16px;
  font-weight: 600;
}

.panel__input {
  padding: 6px 10px;
  border: 1px solid #d0d7de;
  border-radius: 6px;
  font-size: 13px;
  outline: none;
  transition: border-color 0.15s ease;
}

.panel__input:focus {
  border-color: #2f6feb;
}

.panel__item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 0;
}

.panel__amount {
  margin-left: auto;
  color: #cf222e;
  font-variant-numeric: tabular-nums;
}

.panel__amount.is-paid {
  color: #1a7f37;
}

.panel__empty {
  color: #8b949e;
  font-size: 13px;
  text-align: center;
}

@media (max-width: 480px) {
  .panel {
    padding: 8px;
  }
}
</style>
