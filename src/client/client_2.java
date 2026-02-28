package client;

import java.net.*;
import java.awt.*;
import java.awt.event.*;
import java.io.*;
import javax.swing.*;
import javax.swing.border.Border;
import javax.swing.SwingUtilities;

public class client_2 extends JFrame implements ActionListener {
    String message_out;
    JButton send_button;
    JTextArea user = new JTextArea("client_2", 1, 30);   // 用户名
    JTextArea out = new JTextArea(1, 30);   // 发送框
    JTextArea in = new JTextArea(15, 30);   // 接收框
    JPanel pan = new JPanel();

    BufferedReader clientin;
    OutputStream outStream;
    Socket a;

    public client_2() {
        super("Client");
        Border border = BorderFactory.createLineBorder(Color.orange, 1);
        user.setBorder(border);
        in.setBorder(border);
        out.setBorder(border);
        send_button = new JButton("发送");
        send_button.addActionListener(this);     // 点击后执行 actionPerformed

        pan.setLayout(new FlowLayout());
        pan.add(user);
        pan.add(in);
        pan.add(out);
        pan.add(send_button);

        add(pan);
        setSize(350, 370);
        setVisible(true);
        setDefaultCloseOperation(JFrame.DISPOSE_ON_CLOSE);

        try {
            a = new Socket("127.0.0.1", 6667);
            outStream = a.getOutputStream();
            InputStream inStream = a.getInputStream();
            clientin = new BufferedReader(new InputStreamReader(inStream));

            // Start a new thread for message reception
            new Thread(() -> {
                try {
                    String message_in = clientin.readLine();
                    while (!message_in.equals("disconnect")) {
                        String finalMessage_in = message_in;
                        SwingUtilities.invokeLater(() -> {
                            in.append(finalMessage_in + "\n");
                        });
                        message_in = clientin.readLine();
                    }
                } catch (IOException e) {
                    System.out.println("Error: " + e);
                } finally {
                    try {
                        a.close();
                    } catch (IOException e) {
                        System.out.println("Error: " + e);
                    }
                }
            }).start();
        } catch (IOException e) {
            System.out.println("Error: " + e);
        }
    }

    @Override
    public void actionPerformed(ActionEvent e) {
        try {
            message_out = out.getText();
            if (!message_out.equals("disconnect")) {
                outStream.write((user.getText() + "： " + message_out + "\n").getBytes());
                outStream.flush();
            } else {
                outStream.write("disconnect\n".getBytes());
                a.close();
            }
            out.setText("");  // 清空发送框
        } catch (IOException f) {
            System.out.println("Error: " + f);
        }
    }

    public static void main(String[] args) {
        SwingUtilities.invokeLater(() -> new client_2());
    }
}