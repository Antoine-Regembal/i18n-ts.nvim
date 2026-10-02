<script setup lang="ts">
import { useI18n } from "vue-i18n";

const { t } = useI18n();
const props = defineProps<{ items: number; total: string }>();
</script>

<template>
  <section class="cart">
    <h2>{{ t("cart.title") }}</h2>
    <p>{{ t("cart.items", { count: props.items }) }}</p>
    <p>{{ t("cart.total", { amount: props.total }) }}</p>
    <button>{{ t("cart.checkout") }}</button>
    <a href="/shop">{{ t("cart.continue_shopping") }}</a>
    <small>{{ t("cart.free_shipping") }}</small>
  </section>
</template>
