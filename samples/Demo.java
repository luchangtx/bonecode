package com.example.demo;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * 用于试用 BoneCode 编辑器功能的示例文件。
 *
 * 试着把光标放在括号旁边、输入 sout 按 ⌃Space、用 ⌘/ 切换注释、
 * 选中整段按 ⌘⌥F 重排缩进。
 */
public class Demo {

    private static final BigDecimal TAX_RATE = new BigDecimal("0.13");

    private final List<Order> orders = new ArrayList<>();

    public record Order(String id, String customer, BigDecimal amount, boolean paid) {}

    /** 计算已支付订单的含税总额。 */
    public BigDecimal totalWithTax() {
        BigDecimal total = BigDecimal.ZERO;
        for (Order order : orders) {
            if (!order.paid()) {
                continue;
            }
            total = total.add(order.amount());
        }
        return total.multiply(BigDecimal.ONE.add(TAX_RATE));
    }

    public Optional<Order> largestOrder() {
        return orders.stream()
                .filter(Order::paid)
                .max((a, b) -> a.amount().compareTo(b.amount()));
    }

    public List<String> customerNames() {
        return orders.stream()
                .map(Order::customer)
                .distinct()
                .sorted()
                .toList();
    }

    public void seed() {
        orders.add(new Order("A-1001", "张伟", new BigDecimal("1280.00"), true));
        orders.add(new Order("A-1002", "李娜", new BigDecimal("430.50"), false));
        orders.add(new Order("A-1003", "王强", new BigDecimal("2980.00"), true));

        // 光标放在下面这一行的括号里，看看配对高亮
        System.out.println("orders = " + orders.size());
        System.out.println("created at " + LocalDateTime.now());
    }

    public static void main(String[] args) {
        Demo demo = new Demo();
        demo.seed();
        System.out.println("含税总额 = " + demo.totalWithTax());
        demo.largestOrder().ifPresent(o -> System.out.println("最大订单 = " + o.id()));
    }
}
